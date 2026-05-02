#!/usr/bin/env bash
# Smoke test for .github/actions/_grype-summary/scripts/parse.sh.
# Runs the script against checked-in sample SARIF files and verifies the produced
# markdown contains expected anchors (header, severity counts, table rows).
#
# Run: bash scripts/grype-summary.test.sh

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PARSE_SCRIPT="$REPO_ROOT/.github/actions/_grype-summary/scripts/parse.sh"
SAMPLES_DIR="$REPO_ROOT/scripts/grype-summary.test"
WORK_ROOT="$REPO_ROOT/.test-work"
mkdir -p "$WORK_ROOT"

PASS=0
FAIL=0

_read_file() { cat -- "$1"; }

assert_contains() {
  local file="$1" needle="$2" label="$3"
  local body; body=$(_read_file "$file")
  if [[ "$body" == *"$needle"* ]]; then
    echo "  ✅ $label"
    PASS=$((PASS+1))
  else
    echo "  ❌ $label — '$needle' not found in $file"
    FAIL=$((FAIL+1))
  fi
}

assert_not_contains() {
  local file="$1" needle="$2" label="$3"
  local body; body=$(_read_file "$file")
  if [[ "$body" != *"$needle"* ]]; then
    echo "  ✅ $label"
    PASS=$((PASS+1))
  else
    echo "  ❌ $label — '$needle' unexpectedly found in $file"
    FAIL=$((FAIL+1))
  fi
}

run_case() {
  local name="$1" sarif="$2"
  echo "=== $name ==="
  local work
  work=$(mktemp -d -p "$WORK_ROOT")
  local out="$work/out.md"

  SARIF_FILE="$sarif" \
  OUT_MD="$out" \
  CATEGORY="grype-container-test" \
  TOP_N="20" \
  GITHUB_SERVER_URL="https://github.example" \
  GITHUB_REPOSITORY="owner/repo" \
  BRANCH="feature/test-branch" \
    bash "$PARSE_SCRIPT"

  case "$name" in
    mixed)
      assert_contains "$out" "Grype vulnerability scan" "header present"
      assert_contains "$out" "**4 findings:**" "total count rendered"
      assert_contains "$out" "🔴 1 Critical" "critical count"
      assert_contains "$out" "🟠 1 High" "high count"
      assert_contains "$out" "🟡 1 Medium" "medium count"
      assert_contains "$out" "❓ 1 Unknown" "unknown count"
      assert_contains "$out" "CVE-2023-9999" "critical CVE row"
      assert_contains "$out" "CVE-2024-1111" "high CVE row"
      assert_contains "$out" "/usr/lib/x86_64-linux-gnu/libfoo.so.1.0.0" "location rendered"
      assert_contains "$out" "Open Code Scanning alerts for branch" "deep link footer"
      # Pipe inside message must be HTML-encoded or it'd corrupt the table column count.
      assert_not_contains "$out" "malformed input | with pipe char" "literal pipe escaped"
      assert_contains "$out" "malformed input &#124; with pipe char" "pipe rendered as HTML entity"
      assert_contains "$out" "<details>" "table is collapsed"
      ;;
    clean)
      assert_contains "$out" "Grype vulnerability scan" "header present"
      assert_contains "$out" "✅ No vulnerabilities reported." "clean message"
      assert_not_contains "$out" "<details>" "no table when clean"
      ;;
    missing)
      assert_contains "$out" "No SARIF file found" "missing-file message"
      ;;
  esac

  rm -rf "$work"
}

run_case mixed   "$SAMPLES_DIR/sample-mixed.sarif"
run_case clean   "$SAMPLES_DIR/sample-clean.sarif"
run_case missing "$SAMPLES_DIR/does-not-exist.sarif"

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
