#!/usr/bin/env bash
# Tests for .github/actions/_pages-site/scripts/assemble.sh: layers, the badges merge, and carry-
# forward from a live site (served from disk through file://).
#
# Run: bash scripts/pages-site.test.sh   (needs jq and curl)

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASSEMBLE="$REPO_ROOT/.github/actions/_pages-site/scripts/assemble.sh"
WORK="$REPO_ROOT/.test-work/pages-site"
rm -rf "$WORK"
mkdir -p "$WORK"

# Native jq/curl on Windows (MSYS) can't read /tmp or /o/... paths: keep temp files under .test-work
# and give curl a file:///O:/... URL.
export TMPDIR="$WORK"
file_url() { if command -v cygpath > /dev/null; then echo "file:///$(cygpath -m "$1")"; else echo "file://$1"; fi; }

PASS=0
FAIL=0

ok() { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }

assert_file() { # path, expected content (optional)
  if [ ! -f "$1" ]; then bad "$1 missing"; return; fi
  if [ $# -ge 2 ] && [ "$(cat "$1")" != "$2" ]; then bad "$1: expected '$2', got '$(cat "$1")'"; return; fi
  ok "${1#"$WORK"/}"
}

assert_absent() { if [ -e "$1" ]; then bad "${1#"$WORK"/} should not exist"; else ok "${1#"$WORK"/} absent"; fi; }

assert_jq() { # file, filter, label
  if jq -e "$2" "$1" > /dev/null 2>&1; then ok "$3"; else bad "$3 ($2 on ${1#"$WORK"/})"; fi
}

assemble() { # site, layers-file, badges-dirs, base-url, carry-forward
  SITE="$1" LAYERS_FILE="$2" BADGES_DIRS="$3" BASE_URL="$4" CARRY_FORWARD="$5" REPO=owner/app \
    bash "$ASSEMBLE" > "$WORK/last.log" 2>&1
}

# Sources
mkdir -p "$WORK/src/html/css" "$WORK/src/report" "$WORK/src/badges-a" "$WORK/src/badges-b" "$WORK/src/report2"
echo home > "$WORK/src/html/index.html"
echo css > "$WORK/src/html/css/site.css"
echo "report v1" > "$WORK/src/report/index.html"
echo "old page" > "$WORK/src/report/old.html"
echo "report v2" > "$WORK/src/report2/index.html"
echo '<svg>tests</svg>' > "$WORK/src/badges-a/tests-unit.svg"
echo '<svg>nightly</svg>' > "$WORK/src/badges-b/nightly-e2e.svg"
echo '<svg>bad</svg>' > "$WORK/src/badges-b/Bad Name.svg"

echo "first deploy: root html, a report and badges"
printf '%s\n' "$WORK/src/report=reports/coverage" "$WORK/src/html=." > "$WORK/layers1"
if assemble "$WORK/site1" "$WORK/layers1" "$WORK/src/badges-a" "" true; then ok "assemble"; else bad "assemble: $(cat "$WORK/last.log")"; fi
assert_file "$WORK/site1/index.html" home
assert_file "$WORK/site1/css/site.css" css
assert_file "$WORK/site1/reports/coverage/index.html" "report v1"
assert_file "$WORK/site1/badges/tests-unit.svg" '<svg>tests</svg>'
assert_jq "$WORK/site1/site-manifest.json" '.schemaVersion == 1 and .repository == "owner/app"' "manifest header"
assert_jq "$WORK/site1/site-manifest.json" '.layers["."] == ["css/site.css", "index.html"]' "root layer lists only its own files"
assert_jq "$WORK/site1/site-manifest.json" '.layers["reports/coverage"] == ["index.html", "old.html"]' "report layer"
assert_jq "$WORK/site1/site-manifest.json" '.layers.badges == ["tests-unit.svg"]' "badges layer"

LIVE=$(file_url "$WORK/site1")

echo "second deploy: only a nightly badge (artifact into badges), everything else carried forward"
printf '%s\n' "$WORK/src/badges-b=badges" > "$WORK/layers2"
if assemble "$WORK/site2" "$WORK/layers2" "" "$LIVE" true; then ok "assemble"; else bad "assemble: $(cat "$WORK/last.log")"; fi
assert_file "$WORK/site2/index.html" home
assert_file "$WORK/site2/css/site.css" css
assert_file "$WORK/site2/reports/coverage/old.html" "old page"
assert_file "$WORK/site2/badges/tests-unit.svg" '<svg>tests</svg>'
assert_file "$WORK/site2/badges/nightly-e2e.svg" '<svg>nightly</svg>'
assert_absent "$WORK/site2/badges/Bad Name.svg"
assert_jq "$WORK/site2/site-manifest.json" '.layers.badges == ["nightly-e2e.svg", "tests-unit.svg"]' "badges merged"
assert_jq "$WORK/site2/site-manifest.json" '.layers["reports/coverage"] == ["index.html", "old.html"]' "report layer carried forward"

echo "third deploy: a new report replaces its layer completely"
printf '%s\n' "$WORK/src/report2=reports/coverage" > "$WORK/layers3"
if assemble "$WORK/site3" "$WORK/layers3" "" "$(file_url "$WORK/site2")" true; then ok "assemble"; else bad "assemble: $(cat "$WORK/last.log")"; fi
assert_file "$WORK/site3/reports/coverage/index.html" "report v2"
assert_absent "$WORK/site3/reports/coverage/old.html"
assert_file "$WORK/site3/index.html" home
assert_file "$WORK/site3/badges/nightly-e2e.svg" '<svg>nightly</svg>'

echo "carry_forward false: only this run's layers"
if assemble "$WORK/site4" "$WORK/layers3" "" "$(file_url "$WORK/site2")" false; then ok "assemble"; else bad "assemble: $(cat "$WORK/last.log")"; fi
assert_absent "$WORK/site4/badges"
assert_absent "$WORK/site4/css/site.css"
assert_jq "$WORK/site4/site-manifest.json" '.layers | keys == ["reports/coverage"]' "one layer"
assert_file "$WORK/site4/index.html"
if grep -q 'href="reports/coverage/"' "$WORK/site4/index.html"; then ok "generated index links the layer"; else bad "generated index"; fi

echo "unsafe paths"
printf '%s\n' "$WORK/src/html=../escape" > "$WORK/layers5"
if assemble "$WORK/site5" "$WORK/layers5" "" "" true; then bad "../ target accepted"; else ok "../ target rejected"; fi
mkdir -p "$WORK/evil"
jq -n '{schemaVersion: 1, layers: {"x": ["../../outside.txt", "ok.txt"], "../up": ["a.txt"]}}' > "$WORK/evil/site-manifest.json"
mkdir -p "$WORK/evil/x" && echo fine > "$WORK/evil/x/ok.txt"
if assemble "$WORK/site6" "" "" "$(file_url "$WORK/evil")" true; then ok "assemble"; else bad "assemble: $(cat "$WORK/last.log")"; fi
assert_file "$WORK/site6/x/ok.txt" fine
assert_absent "$WORK/outside.txt"
assert_jq "$WORK/site6/site-manifest.json" '.layers | keys == ["x"]' "invalid published layer ignored"

echo
echo "pages-site tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
