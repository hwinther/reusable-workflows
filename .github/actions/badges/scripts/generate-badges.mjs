#!/usr/bin/env node
// Used by the badges action (../action.yml); every input comes in as a CLI flag.
// No network access at render time: badge-maker draws the SVG locally.

import { mkdir, readFile, readdir, stat, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { makeBadge } from "badge-maker";
import { XMLParser } from "fast-xml-parser";

// --- argv parsing -----------------------------------------------------------

const FLAGS = [
  "backend-cobertura",
  "backend-summary-json",
  "frontend-cobertura",
  "frontend-summary-json",
  "e2e-cobertura",
  "lighthouse-json",
  "nightly-status",
  "zap-json",
  "quality-summary-json",
  "out",
];

function parseArgs(argv) {
  const args = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (!a.startsWith("--")) continue;
    const key = a.slice(2);
    if (!FLAGS.includes(key)) {
      throw new Error(`Unknown flag --${key}`);
    }
    const next = argv[i + 1];
    if (!next || next.startsWith("--")) {
      throw new Error(`Flag --${key} needs a value`);
    }
    args[key] = next;
    i++;
  }
  return args;
}

// --- color scale ------------------------------------------------------------

// shields.io standard. Locked for visual consistency across repos that adopt
// this script.
function coverageColor(pct) {
  if (pct < 50) return "red";
  if (pct < 60) return "orange";
  if (pct < 70) return "yellow";
  if (pct < 80) return "yellowgreen";
  if (pct < 90) return "green";
  return "brightgreen";
}

function statusColor(status) {
  switch (status) {
    case "success":
      return "brightgreen";
    case "failure":
      return "red";
    case "cancelled":
      return "lightgrey";
    default:
      return "lightgrey";
  }
}

// --- cobertura parsing ------------------------------------------------------

const xmlParser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: "",
  allowBooleanAttributes: true,
});

async function expandGlob(pattern) {
  // Tiny glob: supports `**/<filename-pattern>` and exact paths. The filename
  // may itself contain `*` (e.g. `coverage.cobertura.*.xml`) which is treated
  // as `[^/]*`. Anything fancier should pre-resolve before passing here.
  if (!pattern.includes("*")) {
    return existsSync(pattern) ? [pattern] : [];
  }
  const idx = pattern.indexOf("**/");
  if (idx === -1) {
    throw new Error(`Unsupported glob: ${pattern} (only **/<name> is supported)`);
  }
  const root = pattern.slice(0, idx) || ".";
  const tail = pattern.slice(idx + 3);
  const tailRe = new RegExp(
    "^" + tail.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*") + "$",
  );
  const matches = [];
  await walk(root, tailRe, matches);
  return matches;
}

async function walk(dir, tailRe, out) {
  let entries;
  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const p = join(dir, e.name);
    if (e.isDirectory()) {
      await walk(p, tailRe, out);
    } else if (e.isFile() && tailRe.test(e.name)) {
      out.push(p);
    }
  }
}

async function readCoberturaPercentage(globOrFile) {
  const files = await expandGlob(globOrFile);
  if (files.length === 0) {
    throw new Error(`No Cobertura XML matched ${globOrFile}`);
  }
  let covered = 0;
  let valid = 0;
  for (const f of files) {
    const xml = await readFile(f, "utf8");
    const doc = xmlParser.parse(xml);
    const root = doc.coverage;
    if (!root) {
      throw new Error(`${f} has no <coverage> root`);
    }
    // Aggregate by sums, never by averaging line-rate. Different shards have
    // different sizes; arithmetic mean gives the wrong answer.
    const c = Number(root["lines-covered"]);
    const v = Number(root["lines-valid"]);
    if (Number.isFinite(c) && Number.isFinite(v) && v > 0) {
      covered += c;
      valid += v;
    } else if (Number.isFinite(Number(root["line-rate"]))) {
      // Fallback: shard didn't emit lines-covered/valid. Use line-rate as a
      // single-shard percentage; only safe when there's exactly one file.
      if (files.length !== 1) {
        throw new Error(
          `${f} only exposes line-rate; can't aggregate ${files.length} shards safely`,
        );
      }
      return Number(root["line-rate"]) * 100;
    }
  }
  if (valid === 0) {
    throw new Error(`No coverable lines reported across ${files.length} files`);
  }
  return (covered / valid) * 100;
}

async function readReportGeneratorSummary(file) {
  const json = JSON.parse(await readFile(file, "utf8"));
  const pct = json?.summary?.linecoverage;
  if (typeof pct !== "number") {
    throw new Error(`${file} has no summary.linecoverage`);
  }
  return pct;
}

// --- lighthouse -------------------------------------------------------------

const LIGHTHOUSE_CATEGORIES = [
  ["performance", "lighthouse perf"],
  ["accessibility", "lighthouse a11y"],
  ["best-practices", "lighthouse bp"],
  ["seo", "lighthouse seo"],
];

async function readLighthouseScores(file) {
  const json = JSON.parse(await readFile(file, "utf8"));
  const cats = json?.categories ?? {};
  const out = {};
  for (const [key, label] of LIGHTHOUSE_CATEGORIES) {
    const score = cats?.[key]?.score;
    if (typeof score === "number") {
      out[key] = { label, pct: Math.round(score * 100) };
    }
  }
  return out;
}

// --- zap --------------------------------------------------------------------

// ZAP JSON report (action-baseline / action-full-scan): site[].alerts[].riskcode
// is "0" (info) | "1" (low) | "2" (medium) | "3" (high). Same alert can appear
// across multiple sites — sum across all to get the run total.
async function readZapFindings(file) {
  const json = JSON.parse(await readFile(file, "utf8"));
  const counts = { high: 0, med: 0, low: 0, info: 0 };
  for (const site of json?.site ?? []) {
    for (const a of site?.alerts ?? []) {
      switch (Number(a.riskcode)) {
        case 3: counts.high++; break;
        case 2: counts.med++; break;
        case 1: counts.low++; break;
        default: counts.info++;
      }
    }
  }
  return counts;
}

function zapColor({ high, med, low }) {
  if (high > 0) return "red";
  if (med > 0) return "orange";
  if (low > 0) return "yellow";
  return "brightgreen";
}

function zapMessage({ high, med, low }) {
  if (high + med + low === 0) return "clean";
  return `${high}H ${med}M ${low}L`;
}

// --- quality summary ---------------------------------------------------------

// summary.json from the reusable-workflows quality artifact (schemaVersion 1):
// test counts, line/branch coverage, warnings and Grype vulnerabilities of one
// main-branch run. Components are named after their quality-* artifact; the
// two unit stacks get the same names as the coverage badges above.
const COMPONENT_NAMES = { dotnet: "backend", node: "frontend" };

async function readQualitySummary(file) {
  const json = JSON.parse(await readFile(file, "utf8"));
  if (json?.schemaVersion !== 1) {
    throw new Error(`${file}: unsupported schemaVersion ${json?.schemaVersion}`);
  }
  return json;
}

function testsBadge(label, t) {
  const failed = t.failed ?? 0;
  const message = failed > 0 ? `${failed} failed, ${t.passed} passed` : `${t.passed} passed`;
  let color = "brightgreen";
  if (failed > 0) color = "red";
  else if (t.passed === 0) color = "lightgrey";
  return makeBadge({ label, message, color, style: "flat" });
}

function warningsColor(n) {
  if (n === 0) return "brightgreen";
  if (n < 10) return "yellow";
  return "orange";
}

function vulnerabilitiesColor({ critical = 0, high = 0, medium = 0 }) {
  if (critical > 0) return "red";
  if (high > 0) return "orange";
  if (medium > 0) return "yellow";
  return "brightgreen";
}

function vulnerabilitiesMessage({ critical = 0, high = 0, medium = 0, low = 0 }) {
  if (critical + high + medium + low === 0) return "clean";
  return `${critical}C ${high}H ${medium}M ${low}L`;
}

async function emitQualitySummary(outDir, summary, generated) {
  const tests = summary?.totals?.tests ?? {};
  for (const kind of ["unit", "e2e"]) {
    if (tests[kind]) {
      await writeSvg(outDir, `tests-${kind}`, testsBadge(`${kind} tests`, tests[kind]));
      generated[`tests-${kind}`] = tests[kind];
    }
  }

  if (typeof summary?.totals?.warnings === "number") {
    const n = summary.totals.warnings;
    await writeSvg(
      outDir,
      "warnings",
      makeBadge({ label: "warnings", message: String(n), color: warningsColor(n), style: "flat" }),
    );
    generated.warnings = n;
  }

  const vulns = summary?.totals?.vulnerabilities?.bySeverity;
  if (vulns) {
    await writeSvg(
      outDir,
      "vulnerabilities",
      makeBadge({
        label: "image vulnerabilities",
        message: vulnerabilitiesMessage(vulns),
        color: vulnerabilitiesColor(vulns),
        style: "flat",
      }),
    );
    generated.vulnerabilities = vulns;
  }

  for (const [name, component] of Object.entries(summary?.components ?? {})) {
    // Unit stacks and the e2e browser coverage (coverage-e2e.svg; e2e_cobertura wins over it).
    if (component?.kind !== "unit" && component?.kind !== "e2e") continue;
    const label = COMPONENT_NAMES[name] ?? name;
    const lines = component?.coverage?.lines?.percent;
    if (typeof lines === "number") {
      await writeSvg(outDir, `coverage-${label}`, svgCoverage(`${label} coverage`, lines));
      generated[`coverage-${label}`] = lines;
    }
    const branches = component?.coverage?.branches?.percent;
    if (typeof branches === "number") {
      await writeSvg(
        outDir,
        `coverage-${label}-branches`,
        svgCoverage(`${label} branch coverage`, branches),
      );
      generated[`coverage-${label}-branches`] = branches;
    }
  }

  // Unit + e2e lines merged per file (frontend only today).
  const combined = summary?.totals?.coverage?.combined?.lines?.percent;
  if (typeof combined === "number") {
    await writeSvg(outDir, "coverage-combined", svgCoverage("unit+e2e coverage", combined));
    generated["coverage-combined"] = combined;
  }
}

// --- emit -------------------------------------------------------------------

function svgCoverage(label, pct) {
  return makeBadge({
    label,
    message: `${pct.toFixed(1)}%`,
    color: coverageColor(pct),
    style: "flat",
  });
}

function svgStatus(label, status) {
  return makeBadge({
    label,
    message: status,
    color: statusColor(status),
    style: "flat",
  });
}

async function writeSvg(outDir, name, svg) {
  await mkdir(outDir, { recursive: true });
  const path = join(outDir, `${name}.svg`);
  await writeFile(path, svg, "utf8");
  return path;
}

// --- main -------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const outDir = resolve(args.out ?? "badges");
  const generated = {};

  // First, so an explicit coverage input below overwrites the summary's line coverage badge.
  if (args["quality-summary-json"]) {
    const summary = await readQualitySummary(args["quality-summary-json"]);
    await emitQualitySummary(outDir, summary, generated);
  }

  if (args["backend-summary-json"]) {
    const pct = await readReportGeneratorSummary(args["backend-summary-json"]);
    await writeSvg(outDir, "coverage-backend", svgCoverage("backend coverage", pct));
    generated["coverage-backend"] = pct;
  } else if (args["backend-cobertura"]) {
    const pct = await readCoberturaPercentage(args["backend-cobertura"]);
    await writeSvg(outDir, "coverage-backend", svgCoverage("backend coverage", pct));
    generated["coverage-backend"] = pct;
  }

  if (args["frontend-summary-json"]) {
    const pct = await readReportGeneratorSummary(args["frontend-summary-json"]);
    await writeSvg(outDir, "coverage-frontend", svgCoverage("frontend coverage", pct));
    generated["coverage-frontend"] = pct;
  } else if (args["frontend-cobertura"]) {
    const pct = await readCoberturaPercentage(args["frontend-cobertura"]);
    await writeSvg(outDir, "coverage-frontend", svgCoverage("frontend coverage", pct));
    generated["coverage-frontend"] = pct;
  }

  if (args["e2e-cobertura"]) {
    const pct = await readCoberturaPercentage(args["e2e-cobertura"]);
    await writeSvg(outDir, "coverage-e2e", svgCoverage("e2e coverage", pct));
    generated["coverage-e2e"] = pct;
  }

  if (args["lighthouse-json"]) {
    const scores = await readLighthouseScores(args["lighthouse-json"]);
    for (const key of Object.keys(scores)) {
      const { label, pct } = scores[key];
      await writeSvg(outDir, `lighthouse-${key}`, svgCoverage(label, pct));
      generated[`lighthouse-${key}`] = pct;
    }
  }

  if (args["nightly-status"]) {
    const status = args["nightly-status"];
    await writeSvg(outDir, "nightly-e2e", svgStatus("nightly e2e", status));
    generated["nightly-e2e"] = status;
  }

  if (args["zap-json"]) {
    const f = await readZapFindings(args["zap-json"]);
    await writeSvg(
      outDir,
      "security-zap",
      makeBadge({
        label: "zap",
        message: zapMessage(f),
        color: zapColor(f),
        style: "flat",
      }),
    );
    generated["security-zap"] = f;
  }

  process.stdout.write(JSON.stringify({ outDir, generated }, null, 2) + "\n");
}

main().catch((err) => {
  process.stderr.write(`generate-badges: ${err.message}\n`);
  process.exit(1);
});
