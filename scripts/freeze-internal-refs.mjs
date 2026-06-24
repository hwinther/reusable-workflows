// Freezes this repo's *internal* `uses:` references from the floating major tag
// (e.g. `@v2`) to an immutable patch tag (e.g. `@v2.3.5`) so that a single tagged
// commit fully determines all transitive workflow/action code. See
// docs/adr/0001-internal-ref-pinning.md.
//
// Only references to THIS repo (hwinther/reusable-workflows/.github/...) are rewritten;
// third-party SHA pins and the `# vX.Y.Z` comments next to them are left untouched.
// Floating refs `@v{major}` and `@v{major}.{minor}` are rewritten; already-immutable
// three-part refs (`@v2.0.0`) and SHAs are left as-is.
//
// Usage:
//   node scripts/freeze-internal-refs.mjs --tag v2.3.5 [--root <dir>]
// Defaults: --root = process.cwd(); major is taken from <root>/.version-major and
// cross-checked against the major in --tag.

import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const REPO_SLUG = "hwinther/reusable-workflows";

function parseArgs(argv) {
  const args = { root: process.cwd(), tag: null };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--root") args.root = argv[++i];
    else if (a.startsWith("--root=")) args.root = a.slice("--root=".length);
    else if (a === "--tag") args.tag = argv[++i];
    else if (a.startsWith("--tag=")) args.tag = a.slice("--tag=".length);
  }
  return args;
}

function readMajorVersion(root) {
  const raw = readFileSync(join(root, ".version-major"), "utf8").trim();
  const major = Number(raw);
  if (!Number.isInteger(major) || major <= 0) {
    throw new Error(`.version-major must be a positive integer, got "${raw}"`);
  }
  return major;
}

function walk(dir, predicate) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return; // missing root — nothing to do
  }
  for (const entry of entries) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) walk(full, predicate);
    else if (st.isFile()) predicate(full);
  }
}

function findYamlFiles(root) {
  const files = [];
  for (const r of [".github/workflows", ".github/actions"]) {
    walk(join(root, r), (file) => {
      if (file.endsWith(".yml") || file.endsWith(".yaml")) files.push(file);
    });
  }
  return files;
}

function main() {
  const { root, tag } = parseArgs(process.argv);
  if (!tag) throw new Error("missing required --tag <vX.Y.Z>");

  const semver = /^v(\d+)\.(\d+)\.(\d+)(-[0-9A-Za-z.-]+)?$/.exec(tag);
  if (!semver) {
    throw new Error(`--tag "${tag}" is not an immutable vX.Y.Z tag; refusing to freeze.`);
  }
  const tagMajor = Number(semver[1]);
  const declaredMajor = readMajorVersion(root);
  if (tagMajor !== declaredMajor) {
    throw new Error(
      `--tag major (v${tagMajor}) does not match .version-major (v${declaredMajor}).`
    );
  }

  const escapedSlug = REPO_SLUG.replace(/[/.]/g, (c) => "\\" + c);
  // Match `uses: <slug>/.github/<path>@v{major}` or `@v{major}.{minor}` (floating),
  // but NOT `@v{major}.{minor}.{patch}` (already immutable). The trailing
  // (?![\d.]) after the optional `.{minor}` prevents matching a third component.
  const re = new RegExp(
    String.raw`(uses:\s*${escapedSlug}\/\.github\/[^@\s]+)@v${tagMajor}(?:\.\d+)?(?![\d.])`,
    "g"
  );

  const files = findYamlFiles(root);
  let totalRefs = 0;
  const changedFiles = [];

  for (const file of files) {
    const before = readFileSync(file, "utf8");
    let count = 0;
    const after = before.replace(re, (_m, prefix) => {
      count++;
      return `${prefix}@${tag}`;
    });
    if (count > 0) {
      writeFileSync(file, after);
      totalRefs += count;
      changedFiles.push({ file, count });
    }
  }

  console.log(
    `🔒 Froze ${totalRefs} internal ref(s) to @${tag} across ${changedFiles.length} file(s) (major v${tagMajor}).`
  );
  for (const { file, count } of changedFiles) {
    console.log(`  - ${file} (${count})`);
  }
  if (totalRefs === 0) {
    console.log(
      "⚠️  No floating internal refs found to freeze (already frozen, or no self-refs in this repo)."
    );
  }
}

try {
  main();
} catch (err) {
  console.error("❌ freeze-internal-refs failed:");
  console.error(err instanceof Error ? err.message : String(err));
  process.exitCode = 1;
}
