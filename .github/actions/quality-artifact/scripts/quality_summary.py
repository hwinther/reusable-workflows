#!/usr/bin/env python3
"""Build summary.json (schema v1) and a markdown table from a run's `quality-*` artifacts.

Usage: quality_summary.py <reports-dir> <summary.json> <summary.md>

<reports-dir> holds one directory per artifact, as actions/download-artifact writes them: the
directory name minus its `quality-` prefix is the component name. Each component is read by
content, so any language can join by uploading one of these formats:

  tests     TRX (*.trx), JUnit XML (<testsuites>/<testsuite>), Vitest JSON (numTotalTests),
            Playwright JSON (stats.expected)
  coverage  Cobertura XML (<coverage lines-valid=...>), Istanbul coverage-summary.json
  scan      Grype JSON (matches[].vulnerability)
  warnings  {"warnings": {"<source>": <count>, ...}} (dotnet-build and node-build write warnings.json)

Within a component JUnit wins over Vitest JSON, and Cobertura over coverage-summary.json, so a
project that writes both is not counted twice. Several files of the same format add up (one TRX
and one Cobertura per .NET test project); when two test projects cover the same assembly, its
lines count twice, so treat .NET line coverage as approximate.
"""

import json
import os
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


def build(reports):
    components = {}
    directories = sorted(p for p in reports.iterdir() if p.is_dir()) if reports.is_dir() else []
    for directory in directories:
        name = directory.name.removeprefix("quality-")
        component = read_component(directory)
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
    return "### Quality summary\n\n" + "\n".join(rows) + "\n"


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    sys.stdout.reconfigure(encoding="utf-8")
    reports, out_json, out_md = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
    summary = build(reports)
    out_json.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    out_md.write_text(markdown(summary), encoding="utf-8")
    print(markdown(summary))


if __name__ == "__main__":
    main()
