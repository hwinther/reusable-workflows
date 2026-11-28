#!/usr/bin/env bash
# Tests for .github/actions/_unrecognised-failure/scripts/check.sh.
# Run: bash scripts/unrecognised-failure.test.sh (non-zero exit if a case fails).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.github/actions/_unrecognised-failure/scripts/check.sh"
WORK_ROOT="$REPO_ROOT/.test-work/unrecognised-failure"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

PASS=0
FAIL=0

# run <name> <exit_code> <recognised_failed> <output text|-> <initial md|-> <hint>
run() {
  local name="$1" code="$2" recognised="$3" output="$4" md="$5" hint="${6:-}"
  local dir="$WORK_ROOT/$name"
  mkdir -p "$dir"
  : > "$dir/github_output"
  if [ "$output" != "-" ]; then printf '%b' "$output" > "$dir/out.txt"; else : > "$dir/out.txt"; fi
  if [ "$md" != "-" ]; then printf '%b' "$md" > "$dir/section.md"; else rm -f "$dir/section.md"; fi
  LABEL="Build" EXIT_CODE="$code" RECOGNISED_FAILED="$recognised" OUTPUT_FILE="$dir/out.txt" \
    OUT_MD="$dir/section.md" HINT="$hint" TAIL_LINES=3 GITHUB_OUTPUT="$dir/github_output" \
    bash "$SCRIPT" > "$dir/stdout" 2>&1
  echo "rc=$?" >> "$dir/stdout"
}

# check <name> <description> <command...>: the command runs in the case dir.
check() {
  local name="$1" what="$2"
  shift 2
  if (cd "$WORK_ROOT/$name" && "$@") > /dev/null 2>&1; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "❌ $name: $what"
    sed 's/^/    /' "$WORK_ROOT/$name/section.md" 2>/dev/null || true
  fi
}

run success 0 false "all good\n" "## ✅ Build succeeded\n"
check success "exit 0 reports nothing" grep -qx "failed=false" github_output
check success "exit 0 leaves the section alone" grep -qx "## ✅ Build succeeded" section.md

run recognised 1 true "x.cs(1,1): error CS1: boom\n" "## ❌ The following build errors must be fixed:\n- ❌ boom\n"
check recognised "recognised errors are left to the formatter" grep -qx "failed=false" github_output
check recognised "recognised errors keep their section" grep -q "must be fixed" section.md

run unrecognised 1 false "line 1\n\e[31mline 2\e[0m\nCSC : error CS2001: missing\n\`\`\`fence\n" \
  "## ✅ Build succeeded\n\n## ⚠️ Warnings (1 total)\n- ⚠️ W1\n"
check unrecognised "reports the failure" grep -qx "failed=true" github_output
check unrecognised "annotates" grep -q "^::error::Build failed (exit code 1)" stdout
check unrecognised "heading with the exit code" grep -qx "## ❌ Build failed (exit code 1)" section.md
check unrecognised "drops the success line" bash -c '! grep -q "Build succeeded" section.md'
check unrecognised "keeps the warnings" grep -qx -- "- ⚠️ W1" section.md
check unrecognised "shows the last lines, colour stripped" grep -qx "line 2" section.md
check unrecognised "tail is limited" bash -c '! grep -qx "line 1" section.md'
check unrecognised "inner fences are broken up" bash -c '[ "$(grep -c "^\`\`\`" section.md)" -eq 2 ]'

run killed 137 false - - "Out of memory is the usual cause."
check killed "names the signal" grep -qx "## ❌ Build failed (exit code 137, killed (often out of memory))" section.md
check killed "shows the hint" grep -qx "Out of memory is the usual cause." section.md
check killed "says when there is no output" grep -qx "(no output)" section.md

run empty-code "" false "boom\n" "## ✅ Build succeeded\n"
check empty-code "an empty exit code (step skipped) reports nothing" grep -qx "failed=false" github_output

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
