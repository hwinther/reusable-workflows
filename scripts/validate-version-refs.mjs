import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const REPO_SLUG = "hwinther/reusable-workflows";
const ROOT = process.cwd();

function readMajorVersion() {
  const path = join(ROOT, ".version-major");
  const raw = readFileSync(path, "utf8").trim();
  const major = Number(raw);
  if (!Number.isInteger(major) || major <= 0) {
    throw new Error(
      `.version-major must contain a positive integer major version, got "${raw}"`
    );
  }
  return major;
}

function walk(dir, predicate) {
  const entries = readdirSync(dir);
  for (const entry of entries) {
    const full = join(dir, entry);
    const st = statSync(full);
    if (st.isDirectory()) {
      walk(full, predicate);
    } else if (st.isFile()) {
      predicate(full);
    }
  }
}

function findYamlFiles() {
  const files = [];
  const roots = [".github/workflows", ".github/actions"];
  for (const r of roots) {
    const fullRoot = join(ROOT, r);
    try {
      walk(fullRoot, (file) => {
        if (file.endsWith(".yml") || file.endsWith(".yaml")) {
          files.push(file);
        }
      });
    } catch {
      // ignore missing roots
    }
  }
  return files;
}

function validate() {
  const declaredMajor = readMajorVersion();
  const yamlFiles = findYamlFiles();

  // Release mode: run against a freshly cut release tree (after the freeze step) to
  // prove every internal ref is immutable — a full vX.Y.Z tag or a commit SHA, never
  // a floating @v{major} / @v{major}.{minor}. See docs/adr/0001-internal-ref-pinning.md.
  const RELEASE_MODE =
    process.argv.includes("--release") || process.env.VALIDATE_MODE === "release";

  /** @type {Array<{file:string,line:number,message:string}>} */
  const problems = [];

  console.log(
    `🔍 Validating version references for ${REPO_SLUG} (expected major v${declaredMajor}, mode: ${RELEASE_MODE ? "release" : "default"}).`
  );
  if (yamlFiles.length === 0) {
    console.log("No workflow or action YAML files found under .github/ to scan.");
  } else {
    console.log(
      `Scanning ${yamlFiles.length} workflow/action YAML file(s):`
    );
    for (const file of yamlFiles) {
      console.log(`- ${file}`);
    }
  }

  const forbiddenRefs = ["@main", "@HEAD", "@head", "@master"];

  const escapedSlug = REPO_SLUG.replace("/", "\\/");
  const selfRepoPattern = new RegExp(
    String.raw`uses:\s*${escapedSlug}\/\.github\/[^@\s]+@([^\s#]+)`,
    "i"
  );

  for (const file of yamlFiles) {
    const content = readFileSync(file, "utf8");
    const lines = content.split(/\r?\n/);

    lines.forEach((line, idx) => {
      const lineNumber = idx + 1;

      // 1) Forbid non-versioned refs to this repo such as @main, @HEAD, etc.
      for (const bad of forbiddenRefs) {
        const badPattern = new RegExp(
          String.raw`uses:\s*${escapedSlug}\/\.github\/[^@\s]+${bad}`,
          "i"
        );
        if (badPattern.test(line)) {
          problems.push({
            file,
            line: lineNumber,
            message: `Forbidden reference "${bad}" to ${REPO_SLUG} – use a major tag like @v${declaredMajor} instead.`,
          });
          return;
        }
      }

      // 2) Enforce immutability/major rules for versioned refs to this repo
      const match = selfRepoPattern.exec(line);
      if (match) {
        const ref = match[1]; // e.g. v1, v1.2.3, <40-hex-sha>, some-branch

        const semverLike = /^v(\d+)(\.\d+){0,2}(-[0-9A-Za-z.-]+)?$/.exec(ref);
        const fullSemver = /^v\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$/.test(ref);
        const isSha = /^[0-9a-f]{40}$/i.test(ref);

        if (RELEASE_MODE) {
          // Every internal ref must be immutable: a full vX.Y.Z tag or a commit SHA.
          if (isSha) {
            // ok
          } else if (fullSemver) {
            const major = Number(semverLike[1]);
            if (major !== declaredMajor) {
              problems.push({
                file,
                line: lineNumber,
                message: `uses: ...@${ref} does not match declared major v${declaredMajor} in .version-major.`,
              });
            }
          } else if (semverLike) {
            problems.push({
              file,
              line: lineNumber,
              message: `release mode: floating ref @${ref} is not immutable — the freeze step must rewrite it to a full vX.Y.Z tag (or pin a commit SHA).`,
            });
          } else {
            problems.push({
              file,
              line: lineNumber,
              message: `release mode: @${ref} is not an immutable vX.Y.Z tag or commit SHA.`,
            });
          }
        } else {
          // Default (main/PR) mode: enforce a single major for v-prefixed refs.
          if (semverLike) {
            const major = Number(semverLike[1]);
            if (!Number.isNaN(major) && major !== declaredMajor) {
              problems.push({
                file,
                line: lineNumber,
                message: `uses: ...@${ref} does not match declared major v${declaredMajor} in .version-major.`,
              });
            }
          } else {
            problems.push({
              file,
              line: lineNumber,
              message: `uses: ...@${ref} for ${REPO_SLUG} is not a v-prefixed version tag (expected something like v${declaredMajor}).`,
            });
          }
        }
      }
    });
  }

  if (problems.length === 0) {
    console.log(
      `✅ Version reference validation passed. All ${REPO_SLUG} references are compatible with major v${declaredMajor} or no such references were found.`
    );
    return;
  }

  console.error("❌ Version reference validation failed:");
  for (const p of problems) {
    console.error(`- ${p.file}:${p.line} - ${p.message}`);
  }
  process.exitCode = 1;
}

try {
  validate();
} catch (err) {
  console.error("❌ Version reference validation crashed:");
  console.error(err instanceof Error ? err.message : String(err));
  process.exitCode = 1;
}

