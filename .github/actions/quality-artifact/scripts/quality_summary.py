#!/usr/bin/env python3
"""Build summary.json and details.json (schema v1) and a markdown table from a run's `quality-*`
artifacts.

Usage: quality_summary.py <reports-dir> <summary.json> <summary.md> [<details.json>]

<reports-dir> holds one directory per artifact, as actions/download-artifact writes them: the
directory name minus its `quality-` prefix is the component name. Each component is read by
content, so any language can join by uploading one of these formats:

  tests     TRX (*.trx), JUnit XML (<testsuites>/<testsuite>), Vitest JSON (numTotalTests),
            Playwright JSON (stats.expected)
  coverage  Cobertura XML (<coverage lines-valid=...>), Istanbul coverage-summary.json
  scan      Grype JSON (matches[].vulnerability)
  warnings  {"warnings": {"<source>": <count>, ...}} (dotnet-build and node-build write warnings.json),
            plus the warning lines themselves as <source>.warn for details.json

Within a component JUnit wins over Vitest JSON, and Cobertura over coverage-summary.json, so a
project that writes both is not counted twice. Test results of the same format add up (one TRX per
.NET test project). Cobertura files are merged per source file and line (a line counts as covered
if any report covers it), so two test projects covering the same assembly don't count it twice.

When an e2e component carries Cobertura too (playwright-e2e.yml adds the suite's browser coverage to
quality-e2e) and a unit component covers some of the same files, totals.coverage.combined is their
per-line merge: the share of lines either the unit tests or the e2e run cover.

details.json holds what a report needs to drill down: coverage per source file (paths relative to
the repo), warnings grouped by source and code with examples, and every vulnerability match.
"""

import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

SEVERITIES = ["critical", "high", "medium", "low", "negligible", "unknown"]


def local(tag):
    return tag.rsplit("}", 1)[-1]


def num(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0


def empty_tests():
    return {"total": 0, "passed": 0, "failed": 0, "skipped": 0}


def add(into, more):
    for key, value in more.items():
        into[key] = into.get(key, 0) + value


def parse_trx(root):
    counters = next((el for el in root.iter() if local(el.tag) == "Counters"), None)
    if counters is None:
        return None
    a = counters.attrib
    failed = sum(num(a.get(k)) for k in ("failed", "error", "timeout", "aborted"))
    total = num(a.get("total"))
    passed = num(a.get("passed"))
    return {"total": total, "passed": passed, "failed": failed, "skipped": max(total - passed - failed, 0)}


def parse_junit(root):
    suites = [root] if local(root.tag) == "testsuite" else [el for el in root if local(el.tag) == "testsuite"]
    if not suites:
        return None
    tests = empty_tests()
    for suite in suites:
        a = suite.attrib
        total = num(a.get("tests"))
        failed = num(a.get("failures")) + num(a.get("errors"))
        skipped = num(a.get("skipped") or a.get("disabled"))
        add(tests, {"total": total, "passed": total - failed - skipped, "failed": failed, "skipped": skipped})
    return tests


def parse_cobertura(root):
    a = root.attrib
    if "lines-valid" not in a:
        return None
    return {
        "lines": {"covered": num(a.get("lines-covered")), "total": num(a.get("lines-valid"))},
        "branches": {"covered": num(a.get("branches-covered")), "total": num(a.get("branches-valid"))},
    }


def parse_json(data):
    """Returns (kind, value) for a recognised JSON report, else (None, None)."""
    if not isinstance(data, dict):
        return None, None
    if isinstance(data.get("warnings"), dict):  # warnings.json from dotnet-build / node-build
        return "warnings", {str(k): num(v) for k, v in data["warnings"].items()}
    if "numTotalTests" in data:  # Vitest / Jest
        total = num(data.get("numTotalTests"))
        failed = num(data.get("numFailedTests"))
        passed = num(data.get("numPassedTests"))
        return "vitest", {"total": total, "passed": passed, "failed": failed, "skipped": total - passed - failed}
    stats = data.get("stats")
    if isinstance(stats, dict) and "expected" in stats:  # Playwright
        passed = num(stats.get("expected")) + num(stats.get("flaky"))
        failed = num(stats.get("unexpected"))
        skipped = num(stats.get("skipped"))
        return "playwright", {"total": passed + failed + skipped, "passed": passed, "failed": failed, "skipped": skipped}
    if isinstance(data.get("matches"), list):  # Grype
        vulns = {s: 0 for s in SEVERITIES}
        fixable = 0
        for match in data["matches"]:
            vuln = match.get("vulnerability") or {}
            severity = str(vuln.get("severity") or "unknown").lower()
            vulns[severity if severity in vulns else "unknown"] += 1
            if (vuln.get("fix") or {}).get("state") == "fixed":
                fixable += 1
        return "grype", {"bySeverity": vulns, "total": sum(vulns.values()), "fixable": fixable}
    total = data.get("total")
    if isinstance(total, dict) and isinstance(total.get("lines"), dict):  # Istanbul coverage-summary
        return "istanbul", {
            "lines": {"covered": num(total["lines"].get("covered")), "total": num(total["lines"].get("total"))},
            "branches": {"covered": num(total["branches"].get("covered")), "total": num(total["branches"].get("total"))},
        }
    return None, None


CHECKOUT = re.compile(r"^/home/runner/work/[^/]+/[^/]+(/|$)")


def in_checkout(path):
    """True when path is inside the runner's checkout (GITHUB_WORKSPACE)."""
    workspace = os.environ.get("GITHUB_WORKSPACE", "").replace("\\", "/").rstrip("/")
    path = path.replace("\\", "/").rstrip("/")
    return bool(workspace and (path == workspace or path.startswith(workspace + "/"))) or bool(CHECKOUT.match(path + "/"))


def joinable(source):
    """A Cobertura <source> to join relative file names to: relative, or absolute in the checkout."""
    source = source.replace("\\", "/")
    absolute = source.startswith("/") or re.match(r"^[A-Za-z]:", source)
    return not absolute or in_checkout(source)


def repo_relative(path):
    """Strip the runner's checkout path, so file names read as repo paths."""
    workspace = os.environ.get("GITHUB_WORKSPACE", "").rstrip("/")
    path = path.replace("\\", "/")
    if workspace and path.startswith(workspace + "/"):
        return path[len(workspace) + 1:]
    return re.sub(r"^/home/runner/work/[^/]+/[^/]+/", "", path)


CONDITION = re.compile(r"\((\d+)/(\d+)\)")


def cobertura_lines(root):
    """{file: {line: (hits, branches_covered, branches_total)}} from one Cobertura report.

    Relative file names are joined to the report's first <source> when that source is in the
    runner's checkout (unit tests run there). A source outside it is a container path, such as the
    e2e suite's /e2e, whose reporter already writes repo-relative names, so those stay as they are.
    """
    sources = [s.text.strip() for s in root.iter() if local(s.tag) == "source" and s.text and s.text.strip()]
    files = {}
    for cls in (el for el in root.iter() if local(el.tag) == "class"):
        name = (cls.get("filename") or "").replace("\\", "/")
        if not name:
            continue
        if not name.startswith("/") and not re.match(r"^[A-Za-z]:", name) and sources and joinable(sources[0]):
            name = sources[0].replace("\\", "/").rstrip("/") + "/" + name
        lines = files.setdefault(repo_relative(name), {})
        holder = next((el for el in cls if local(el.tag) == "lines"), None)
        for line in (holder if holder is not None else []):
            number = num(line.get("number"))
            hits = num(line.get("hits"))
            covered = total = 0
            if (line.get("branch") or "").lower() == "true":
                m = CONDITION.search(line.get("condition-coverage") or "")
                if m:
                    covered, total = int(m.group(1)), int(m.group(2))
            old = lines.get(number, (0, 0, 0))
            lines[number] = (max(old[0], hits), max(old[1], covered), max(old[2], total))
    return files


def merge_lines(into, more):
    for name, lines in more.items():
        target = into.setdefault(name, {})
        for number, (hits, covered, total) in lines.items():
            old = target.get(number, (0, 0, 0))
            target[number] = (max(old[0], hits), max(old[1], covered), max(old[2], total))


def file_coverage(files):
    out = []
    for name, lines in sorted(files.items()):
        if not lines:
            continue
        entry = {
            "file": name,
            "lines": {"covered": sum(1 for h, _, _ in lines.values() if h > 0), "total": len(lines)},
            "branches": {"covered": sum(c for _, c, _ in lines.values()), "total": sum(t for _, _, t in lines.values())},
        }
        for part in (entry["lines"], entry["branches"]):
            part["percent"] = percent(part)
        out.append(entry)
    return out


WARNING_CODE = re.compile(r"warning:?\s+([A-Za-z@][\w@/.-]*?)\s*:")
WARNING_LOCATION = re.compile(r"^(?P<file>.+?)(?:\((?P<l1>\d+)(?:,\d+)?\)|:(?P<l2>\d+)(?::\d+)?)\s*[:-]\s*warning")


def parse_warning(line):
    line = re.sub(r"\s+\[[^\]]+\.(csproj|fsproj|vbproj|sln|slnx)\]$", "", line.strip())
    code = WARNING_CODE.search(line)
    location = WARNING_LOCATION.match(line)
    message = line[code.end():].strip() if code else line
    return {
        "code": code.group(1) if code else "other",
        "file": repo_relative(location.group("file")) if location else "",
        "line": num(location.group("l1") or location.group("l2")) if location else 0,
        "message": message[:300],
    }


def warning_groups(directory):
    groups = {}
    for path in sorted(directory.glob("*.warn")):
        source = path.stem
        for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
            if not raw.strip():
                continue
            w = parse_warning(raw)
            group = groups.setdefault((source, w["code"]), {"source": source, "code": w["code"], "count": 0, "examples": []})
            group["count"] += 1
            if len(group["examples"]) < 10:
                group["examples"].append({k: w[k] for k in ("file", "line", "message")})
    return sorted(groups.values(), key=lambda g: (-g["count"], g["source"], g["code"]))


def vulnerability_list(component, data):
    seen, out = set(), []
    for match in data.get("matches", []):
        vuln = match.get("vulnerability") or {}
        artifact = match.get("artifact") or {}
        key = (vuln.get("id"), artifact.get("name"), artifact.get("version"))
        if key in seen:
            continue
        seen.add(key)
        fix = vuln.get("fix") or {}
        out.append({
            "component": component,
            "id": vuln.get("id"),
            "severity": str(vuln.get("severity") or "unknown").lower(),
            "package": artifact.get("name"),
            "version": artifact.get("version"),
            "type": artifact.get("type"),
            "fixedIn": (fix.get("versions") or []) if fix.get("state") == "fixed" else [],
            "url": vuln.get("dataSource") or "",
        })
    return out


def build_details(reports, line_maps=None):
    """details.json; line_maps, when given, receives each component's per-line coverage."""
    details = {"schemaVersion": 1, "coverage": {}, "warnings": {}, "vulnerabilities": []}
    directories = sorted(p for p in reports.iterdir() if p.is_dir()) if reports.is_dir() else []
    for directory in directories:
        name = directory.name.removeprefix("quality-")
        files = {}
        for path in sorted(directory.rglob("*")):
            if path.suffix.lower() == ".xml":
                try:
                    root = ET.parse(path).getroot()
                except ET.ParseError:
                    continue
                if local(root.tag) == "coverage":
                    merge_lines(files, cobertura_lines(root))
            elif path.suffix.lower() == ".json":
                try:
                    data = json.loads(path.read_text(encoding="utf-8"))
                except (ValueError, UnicodeDecodeError):
                    continue
                if isinstance(data, dict) and isinstance(data.get("matches"), list):
                    details["vulnerabilities"] += vulnerability_list(name, data)
        if files:
            details["coverage"][name] = {"files": file_coverage(files)}
            if line_maps is not None:
                line_maps[name] = files
        groups = warning_groups(directory)
        if groups:
            details["warnings"][name] = groups
    order = {s: i for i, s in enumerate(SEVERITIES)}
    details["vulnerabilities"].sort(key=lambda v: (order.get(v["severity"], 99), v["component"], v["id"] or ""))
    return details


def percent(part):
    return round(100 * part["covered"] / part["total"], 2) if part["total"] else None


def read_component(directory):
    found = {"trx": [], "junit": [], "vitest": [], "playwright": [], "cobertura": [], "istanbul": [], "grype": [], "warnings": []}
    for path in sorted(directory.rglob("*")):
        if not path.is_file():
            continue
        if path.suffix.lower() in (".xml", ".trx"):
            try:
                root = ET.parse(path).getroot()
            except ET.ParseError:
                continue
            name = local(root.tag)
            if name == "TestRun":
                value, kind = parse_trx(root), "trx"
            elif name in ("testsuites", "testsuite"):
                value, kind = parse_junit(root), "junit"
            elif name == "coverage":
                value, kind = parse_cobertura(root), "cobertura"
            else:
                continue
        elif path.suffix.lower() == ".json":
            try:
                kind, value = parse_json(json.loads(path.read_text(encoding="utf-8")))
            except (ValueError, UnicodeDecodeError):
                continue
        else:
            continue
        if value is not None:
            found[kind].append(value)

    component = {}
    test_sources = next((found[k] for k in ("trx", "junit", "vitest", "playwright") if found[k]), [])
    if test_sources:
        tests = empty_tests()
        for value in test_sources:
            add(tests, value)
        component["kind"] = "e2e" if found["playwright"] and not (found["trx"] or found["junit"] or found["vitest"]) else "unit"
        component["tests"] = tests
    coverage_sources = found["cobertura"] or found["istanbul"]
    if coverage_sources:
        coverage = {"lines": {"covered": 0, "total": 0}, "branches": {"covered": 0, "total": 0}}
        for value in coverage_sources:
            for key in coverage:
                add(coverage[key], value[key])
        for part in coverage.values():
            part["percent"] = percent(part)
        component.setdefault("kind", "unit")
        component["coverage"] = coverage
    if found["warnings"]:
        warnings = {}
        for value in found["warnings"]:
            add(warnings, value)
        warnings["total"] = sum(warnings.values())
        component.setdefault("kind", "unit")
        component["warnings"] = warnings
    if found["grype"]:
        vulns = {"bySeverity": {s: 0 for s in SEVERITIES}, "total": 0, "fixable": 0}
        for value in found["grype"]:
            add(vulns["bySeverity"], value["bySeverity"])
            vulns["total"] += value["total"]
            vulns["fixable"] += value["fixable"]
        component.setdefault("kind", "scan")
        component["vulnerabilities"] = vulns
    return component


def combined_coverage(components, line_maps):
    """Line coverage of the e2e components merged with the unit components that cover the same files.

    A line counts as covered when either side covers it. Only when an e2e component has per-line
    coverage and a unit component shares at least one file with it (the frontend's unit tests, not
    the backend's), else None. Approximate: unit reporters count statement lines, V8 counts every
    executable line, so a file both cover has the union of both line sets.
    """
    e2e = [n for n, c in components.items() if c.get("kind") == "e2e" and n in line_maps]
    e2e_files = {f for n in e2e for f in line_maps[n]}
    unit = [n for n, c in components.items() if c.get("kind") == "unit" and set(line_maps.get(n, {})) & e2e_files]
    if not e2e or not unit:
        return None
    merged = {}
    for name in unit + e2e:
        merge_lines(merged, line_maps[name])
    files = file_coverage(merged)
    lines = {"covered": sum(f["lines"]["covered"] for f in files), "total": sum(f["lines"]["total"] for f in files)}
    lines["percent"] = percent(lines)
    return {"components": unit + e2e, "lines": lines}


def build(reports, details=None, line_maps=None):
    components = {}
    directories = sorted(p for p in reports.iterdir() if p.is_dir()) if reports.is_dir() else []
    for directory in directories:
        name = directory.name.removeprefix("quality-")
        component = read_component(directory)
        # Prefer the per-line merge over summed report totals when Cobertura had line data.
        files = ((details or {}).get("coverage") or {}).get(name, {}).get("files")
        if files and "coverage" in component:
            coverage = {key: {"covered": sum(f[key]["covered"] for f in files), "total": sum(f[key]["total"] for f in files)}
                        for key in ("lines", "branches")}
            for part in coverage.values():
                part["percent"] = percent(part)
            component["coverage"] = coverage
        if component:
            components[name] = component

    totals = {"tests": {}, "warnings": 0, "vulnerabilities": {"bySeverity": {s: 0 for s in SEVERITIES}, "total": 0, "fixable": 0}}
    for component in components.values():
        if "tests" in component:
            add(totals["tests"].setdefault(component["kind"], empty_tests()), component["tests"])
        if "warnings" in component:
            totals["warnings"] += component["warnings"]["total"]
        if "vulnerabilities" in component:
            add(totals["vulnerabilities"]["bySeverity"], component["vulnerabilities"]["bySeverity"])
            totals["vulnerabilities"]["total"] += component["vulnerabilities"]["total"]
            totals["vulnerabilities"]["fixable"] += component["vulnerabilities"]["fixable"]
    combined = combined_coverage(components, line_maps or {})
    if combined:
        totals["coverage"] = {"combined": combined}

    env = os.environ.get
    server, repo, run_id = env("GITHUB_SERVER_URL", "https://github.com"), env("GITHUB_REPOSITORY", ""), env("GITHUB_RUN_ID", "")
    return {
        "schemaVersion": 1,
        "repository": repo,
        "commit": env("GITHUB_SHA", ""),
        "ref": env("GITHUB_REF", ""),
        "version": env("QUALITY_VERSION", ""),
        "createdAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run": {"id": run_id, "url": f"{server}/{repo}/actions/runs/{run_id}" if repo and run_id else ""},
        "components": components,
        "totals": totals,
    }


def markdown(summary):
    def tests(t):
        return f"{t['passed']}/{t['total']} passed" + (f", **{t['failed']} failed**" if t["failed"] else "") + (f", {t['skipped']} skipped" if t["skipped"] else "")

    def cov(c):
        lines, branches = c["lines"]["percent"], c["branches"]["percent"]
        return " / ".join(f"{label} {value:.1f} %" for label, value in (("lines", lines), ("branches", branches)) if value is not None)

    def vulns(v):
        shown = [f"{v['bySeverity'][s]} {s}" for s in SEVERITIES if v["bySeverity"][s]]
        return (", ".join(shown) or "none") + (f" ({v['fixable']} fixable)" if v["fixable"] else "")

    def warns(w):
        return str(w["total"]) + (" (" + ", ".join(f"{k} {v}" for k, v in w.items() if k != "total" and v) + ")" if w["total"] else "")

    rows = ["| Component | Kind | Tests | Coverage | Warnings | Vulnerabilities |", "|---|---|---|---|---|---|"]
    for name, c in summary["components"].items():
        rows.append(
            f"| `{name}` | {c.get('kind', '')} | {tests(c['tests']) if 'tests' in c else ''} "
            f"| {cov(c['coverage']) if 'coverage' in c else ''} | {warns(c['warnings']) if 'warnings' in c else ''} "
            f"| {vulns(c['vulnerabilities']) if 'vulnerabilities' in c else ''} |"
        )
    if not summary["components"]:
        rows.append("| _no `quality-*` reports found_ | | | | | |")
    combined = summary["totals"].get("coverage", {}).get("combined")
    if combined and combined["lines"]["percent"] is not None:
        names = " + ".join(f"`{n}`" for n in combined["components"])
        rows.append(f"\nCombined line coverage ({names}, covered by either): {combined['lines']['percent']:.1f} % "
                    f"({combined['lines']['covered']}/{combined['lines']['total']})")
    return "### Quality summary\n\n" + "\n".join(rows) + "\n"


def main():
    if len(sys.argv) not in (4, 5):
        sys.exit(__doc__)
    sys.stdout.reconfigure(encoding="utf-8")
    reports, out_json, out_md = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    line_maps = {}
    details = build_details(reports, line_maps)
    summary = build(reports, details, line_maps)
    if len(sys.argv) == 5:
        Path(sys.argv[4]).write_text(json.dumps(details, separators=(",", ":")) + "\n", encoding="utf-8")
    out_json.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    out_md.write_text(markdown(summary), encoding="utf-8")
    print(markdown(summary))


if __name__ == "__main__":
    main()
