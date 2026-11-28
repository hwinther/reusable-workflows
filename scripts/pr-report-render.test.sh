#!/usr/bin/env bash
# Tests for .github/actions/_pr-report-render/scripts/render.sh.
# Run: bash scripts/pr-report-render.test.sh (non-zero exit if a case fails).
# The checks read their variables inside ok()'s eval, which shellcheck can't see.
# shellcheck disable=SC2034
set -uo pipefail
export LC_ALL=C.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.github/actions/_pr-report-render/scripts/render.sh"
WORK="$REPO_ROOT/.test-work/pr-report-render"
rm -rf "$WORK"
mkdir -p "$WORK"

PASS=0
FAIL=0
ok() { if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "❌ $1"; fi; }

# section <case> <run_id> <artifact> <status.json> [report.md]
section() {
  local d="$WORK/$1/runs/$2/$3"
  mkdir -p "$d"
  printf '%s' "$4" > "$d/status.json"
  [ $# -ge 5 ] && printf '%b' "$5" > "$d/report.md"
  return 0
}
render() {
  local c="$1"
  shift
  mkdir -p "$WORK/$c/runs"
  env RUNNER_TEMP="$WORK" REPORTS_DIR="$WORK/$c" SHA=abc1234def OUT_MD="$WORK/$c/out.md" RUNS_URL="https://github.com/o/r/actions/runs" \
    AGGREGATOR_URL="https://github.com/o/r/actions/runs/9" NOW="2026-11-28 12:00 UTC" IN_PROGRESS="" "$@" bash "$SCRIPT"
}

# --- main: several sections, a re-run, a broken file, a running workflow
section main 100 pr-report-build-node '{"id":"build-node","title":"Build · Node","status":"success","order":10}' "## ✅ Build succeeded\n"
section main 100 pr-report-build-dotnet '{"id":"build-dotnet","title":"Build · .NET","status":"failure","summary":"2 errors","order":10}' "## ❌ errors\n- x\n"
section main 101 pr-report-build-dotnet '{"id":"build-dotnet","title":"Build · .NET","status":"success","order":10}' "## ✅ Build succeeded (re-run)\n"
section main 200 pr-report-scan '{"id":"scan","title":"Image scan | api","status":"warning","summary":"2 high","order":30}' "two highs\n"
section main 200 pr-report-junk 'not json'
render main IN_PROGRESS=$'PR e2e\n'
out="$WORK/main/out.md"
header='## 🧾 PR status — `abc1234`'
ok "header has the short sha" '[ "$(head -n 1 "$out")" = "$header" ]'
ok "the later run of a section wins" 'grep -q "Build succeeded (re-run)" "$out" && ! grep -q "2 errors" "$out"'
ok "the later run is linked" 'grep -q "| ✅ Build · .NET | passed | \[run\](https://github.com/o/r/actions/runs/101) |" "$out"'
ok "sorted by order, then title" '[ "$(grep -n "Build · .NET |" "$out" | cut -d: -f1)" -lt "$(grep -n "Build · Node |" "$out" | cut -d: -f1)" ] && [ "$(grep -n "Build · Node |" "$out" | cut -d: -f1)" -lt "$(grep -n "Image scan" "$out" | head -1 | cut -d: -f1)" ]'
ok "a pipe in a title is escaped in the table" 'grep -qF "| ⚠️ Image scan \| api | warnings · 2 high |" "$out"'
ok "running workflows are listed" 'grep -qx "| ⏳ PR e2e | running | |" "$out"'
ok "a broken status.json is skipped" '[ "$(grep -c "^| " "$out")" -eq 5 ]'
ok "problem sections are open" 'grep -qx "<details open><summary>⚠️ Image scan | api</summary>" "$out"'
ok "passing sections are closed" 'grep -qx "<details><summary>✅ Build · Node</summary>" "$out"'
ok "section headings are demoted" 'grep -qx "#### ✅ Build succeeded" "$out" && ! grep -q "^## ✅" "$out"'
ok "footer links the aggregator" 'grep -qx "<sub>Updated 2026-11-28 12:00 UTC by \[pr-report\](https://github.com/o/r/actions/runs/9).</sub>" "$out"'

# --- empty: nothing yet
render empty
ok "no reports says so" 'grep -qx "No reports for this commit yet." "$WORK/empty/out.md"'

# --- long section body is capped with the fence closed
long=$'```\n'; for i in $(seq 1 300); do long+="line $i of the output"$'\n'; done
section long 300 pr-report-tests '{"id":"tests","title":"Tests","status":"failure"}' "$long"
render long MAX_SECTION_CHARS=500
lo="$WORK/long/out.md"
ok "a long body is cut" 'grep -q "cut here; the full report is in the job summary of \[the run\](https://github.com/o/r/actions/runs/300)" "$lo"'
ok "its code fence is closed" '[ $(( $(grep -c "^\`\`\`" "$lo") % 2 )) -eq 0 ]'
ok "missing summary and default order are fine" 'grep -q "| ❌ Tests | failed |" "$lo"'

# --- a section without report.md
section nobody 400 pr-report-x '{"id":"x","title":"X","status":"neutral"}'
render nobody
ok "no report.md reads as no details" 'grep -qx "_No details._" "$WORK/nobody/out.md"'
ok "neutral has no result word" 'grep -q "| ℹ️ X | – |" "$WORK/nobody/out.md"'

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
