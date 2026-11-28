#!/usr/bin/env bash
# Tests for .github/actions/_sticky-pr-comment/scripts/body.sh.
# Run: bash scripts/sticky-pr-comment.test.sh (non-zero exit if a case fails).
set -uo pipefail
export LC_ALL=C.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.github/actions/_sticky-pr-comment/scripts/body.sh"
WORK="$REPO_ROOT/.test-work/sticky-pr-comment"
rm -rf "$WORK"
mkdir -p "$WORK"

PASS=0
FAIL=0
MARKER="<!-- sticky-pr-comment: test -->"

# body <name> [VAR=value ...]: runs body.sh with the given environment.
body() {
  local name="$1"
  shift
  env MARKER="$MARKER" BODY_FILE="$WORK/$name.md" CONTENT="" FALLBACK_CONTENT="" DELETE_WHEN_EMPTY=false \
    RUN_URL="https://github.com/o/r/actions/runs/1" "$@" bash "$SCRIPT" > "$WORK/$name.action"
}

ok() {
  if eval "$2"; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "❌ $1"; fi
}

body plain CONTENT=$'## ✅ Build succeeded\n- fine'
ok "content is posted" '[ "$(cat "$WORK/plain.action")" = post ]'
ok "body is the marker then the content" '[ "$(cat "$WORK/plain.md")" = "$MARKER"$'"'"'\n## ✅ Build succeeded\n- fine'"'"' ]'

body fallback CONTENT=$'  \n' FALLBACK_CONTENT="## ❌ No build report"
ok "blank content uses the fallback" 'grep -qx "## ❌ No build report" "$WORK/fallback.md"'

body delete DELETE_WHEN_EMPTY=true
ok "nothing to say + delete_when_empty deletes" '[ "$(cat "$WORK/delete.action")" = delete ]'
ok "and writes no body" '[ ! -e "$WORK/delete.md" ]'

body legacy
ok "nothing to say without delete posts the marker only (unchanged behaviour)" '[ "$(cat "$WORK/legacy.md")" = "$MARKER" ]'

long=$'## ❌ Tests failed\n\n```\n'
for i in $(seq 1 400); do long+="line $i: æøå something went wrong here"$'\n'; done
long+=$'```\n'
body long CONTENT="$long" MAX_CHARS=2000
len="$(wc -m < "$WORK/long.md" | tr -d ' ')"
ok "a long body is cut below the limit ($len chars)" '[ "$len" -le 2000 ]'
ok "it says it was truncated, with the run link" 'tail -n 1 "$WORK/long.md" | grep -q "^… truncated: the report was [0-9]* characters.*\[the workflow run\](https://github.com/o/r/actions/runs/1)"'
ok "an open code fence is closed" '[ $(( $(grep -c "^\`\`\`" "$WORK/long.md") % 2 )) -eq 0 ]'
ok "it is cut at a line break" 'grep -q "^line [0-9]*: æøå something went wrong here$" "$WORK/long.md" && ! grep -qE "^line [0-9]+: [^s]*$" "$WORK/long.md"'

body short CONTENT="$long" MAX_CHARS=100000
ok "a body under the limit is untouched" '! grep -q "truncated" "$WORK/short.md"'

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
