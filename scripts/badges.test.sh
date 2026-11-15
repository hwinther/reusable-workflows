#!/usr/bin/env bash
# Smoke test for .github/actions/badges/scripts/generate-badges.mjs.
# Renders the checked-in quality summaries and checks each badge's <title> (label: message) and
# colour, plus that a badge without data is not rendered.
#
# Run: bash scripts/badges.test.sh   (needs node >= 20 and npm)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_DIR="$REPO_ROOT/.github/actions/badges/scripts"
SAMPLES_DIR="$REPO_ROOT/scripts/badges.test"
WORK_ROOT="$REPO_ROOT/.test-work/badges"
rm -rf "$WORK_ROOT"
mkdir -p "$WORK_ROOT"

PASS=0
FAIL=0

(cd "$ACTION_DIR" && npm ci --ignore-scripts --no-audit --no-fund --silent) || { echo "npm ci failed"; exit 1; }

render() {
  local name="$1"; shift
  node "$ACTION_DIR/generate-badges.mjs" "$@" --out "$WORK_ROOT/$name" > "$WORK_ROOT/$name.json" \
    || { echo "  ❌ render $name failed"; FAIL=$((FAIL+1)); }
}

assert_badge() {
  local dir="$1" badge="$2" title="$3" colour="$4"
  local file="$WORK_ROOT/$dir/$badge.svg"
  if [ ! -f "$file" ]; then
    echo "  ❌ $dir/$badge.svg missing"
    FAIL=$((FAIL+1))
    return
  fi
  local body; body=$(cat -- "$file")
  if [[ "$body" == *"<title>$title</title>"* && "$body" == *"$colour"* ]]; then
    echo "  ✅ $dir/$badge: $title"
    PASS=$((PASS+1))
  else
    echo "  ❌ $dir/$badge: expected '<title>$title</title>' and $colour in $file"
    FAIL=$((FAIL+1))
  fi
}

assert_absent() {
  local dir="$1" badge="$2"
  if [ -f "$WORK_ROOT/$dir/$badge.svg" ]; then
    echo "  ❌ $dir/$badge.svg should not be rendered"
    FAIL=$((FAIL+1))
  else
    echo "  ✅ $dir/$badge.svg not rendered"
    PASS=$((PASS+1))
  fi
}

# badge-maker 6 colour names as hex (node_modules/badge-maker/lib/color.js).
BRIGHTGREEN="#4b0"
GREEN="#67ac09"
YELLOW="#d8b800"
ORANGE="#ea7233"
RED="#dd4343"

echo "green summary"
render green --quality-summary-json "$SAMPLES_DIR/summary.json"
assert_badge green tests-unit "unit tests: 284 passed" "$BRIGHTGREEN"
assert_badge green tests-e2e "e2e tests: 25 passed" "$BRIGHTGREEN"
assert_badge green warnings "warnings: 0" "$BRIGHTGREEN"
assert_badge green vulnerabilities "image vulnerabilities: 0C 13H 58M 10L" "$ORANGE"
assert_badge green coverage-backend "backend coverage: 86.5%" "$GREEN"
assert_badge green coverage-backend-branches "backend branch coverage: 62.7%" "$YELLOW"
assert_badge green coverage-frontend "frontend coverage: 98.1%" "$BRIGHTGREEN"
assert_badge green coverage-frontend-branches "frontend branch coverage: 93.5%" "$BRIGHTGREEN"
assert_badge green coverage-combined "unit+e2e coverage: 95.0%" "$BRIGHTGREEN"
assert_badge green coverage-e2e "e2e coverage: 85.5%" "$GREEN"
assert_badge green coverage-e2e-branches "e2e branch coverage: 62.6%" "$YELLOW"

echo "failing summary"
render failing --quality-summary-json "$SAMPLES_DIR/failing.json"
assert_badge failing tests-unit "unit tests: 3 failed, 281 passed" "$RED"
assert_badge failing warnings "warnings: 12" "$ORANGE"
assert_badge failing vulnerabilities "image vulnerabilities: 1C 13H 58M 10L" "$RED"
assert_absent failing tests-e2e
assert_absent failing coverage-combined

echo "explicit input wins over the summary"
render override --quality-summary-json "$SAMPLES_DIR/summary.json" --nightly-status failure \
  --frontend-cobertura "$SAMPLES_DIR/cobertura.xml"
assert_badge override coverage-frontend "frontend coverage: 40.0%" "$RED"
assert_badge override nightly-e2e "nightly e2e: failure" "$RED"

echo "custom badges"
render custom --quality-summary-json "$SAMPLES_DIR/summary.json" --custom-file "$SAMPLES_DIR/custom.txt"
assert_badge custom pkg-pve-manager "pve-manager: 9.2.28-wsh2" "#007ec6"
assert_badge custom distro "debian: trixie" "#a80030"
assert_badge custom warnings "warnings: overridden" "$GREEN"
if node "$ACTION_DIR/generate-badges.mjs" --custom-file "$SAMPLES_DIR/custom-bad.txt" --out "$WORK_ROOT/custom-bad" > /dev/null 2>&1; then
  echo "  ❌ invalid custom badge name accepted"; FAIL=$((FAIL+1))
else
  echo "  ✅ invalid custom badge name rejected"; PASS=$((PASS+1))
fi

echo
echo "badges tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
