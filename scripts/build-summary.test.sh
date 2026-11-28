#!/usr/bin/env bash
# Tests for .github/actions/_build-summary/scripts/summary.sh.
# Run: bash scripts/build-summary.test.sh (non-zero exit if a case fails).
set -uo pipefail
export LC_ALL=C.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.github/actions/_build-summary/scripts/summary.sh"
WORK="$REPO_ROOT/.test-work/build-summary"
rm -rf "$WORK"
mkdir -p "$WORK"

PASS=0
FAIL=0

# expect <case> <expected summary> <expected status> [VAR=value ...]
expect() {
  local name="$1" want_summary="$2" want_status="$3"
  shift 3
  local out="$WORK/$name.out"
  : > "$out"
  env GITHUB_OUTPUT="$out" "$@" bash "$SCRIPT" > /dev/null 2>&1
  local got_summary got_status
  got_summary="$(sed -n 's/^summary=//p' "$out")"
  got_status="$(sed -n 's/^status=//p' "$out")"
  if [ "$got_summary" = "$want_summary" ] && [ "$got_status" = "$want_status" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "❌ $name"
    echo "    want: [$want_status] $want_summary"
    echo "    got:  [$got_status] $got_summary"
  fi
}

# --- fixtures
trx() { # trx <dir> <total> <passed> <failed> [error] [notExecuted]
  mkdir -p "$1/TestResults"
  cat > "$1/TestResults/run-$RANDOM.trx" <<XML
<?xml version="1.0" encoding="utf-8"?>
<TestRun xmlns="http://microsoft.com/schemas/VisualStudio/TeamTest/2010">
  <ResultSummary outcome="Completed">
    <Counters total="$2" executed="$2" passed="$3" failed="$4" error="${5:-0}" timeout="0" aborted="0" inconclusive="0" passedButRunAborted="0" notRunnable="0" notExecuted="${6:-0}" disconnected="0" warning="0" completed="0" inProgress="0" pending="0" />
  </ResultSummary>
</TestRun>
XML
}
cobertura() { # cobertura <file> <covered> <valid>
  mkdir -p "$(dirname "$1")"
  printf '<?xml version="1.0" encoding="utf-8"?>\n<coverage line-rate="0.5" branch-rate="0" version="1.9" timestamp="1" lines-covered="%s" lines-valid="%s" branches-covered="0" branches-valid="0">\n  <packages />\n</coverage>\n' "$2" "$3" > "$1"
}

D="$WORK/dotnet"
trx "$D/tests/Api.Tests" 48 48 0
trx "$D/tests/Gen.Tests" 3 3 0
cobertura "$D/tests/Api.Tests/TestResults/x/coverage.cobertura.1.xml" 800 1000
cobertura "$D/tests/Gen.Tests/TestResults/y/coverage.cobertura.2.xml" 42 100

expect dotnet-green "51/51 tests · 🟡 76.5 % lines" success \
  STEPS=$'restore|0|false|0\nbuild|0|false|0' WARNINGS="0 0 0" TESTS_FORMAT=trx TESTS_PATH="$D" \
  COVERAGE_DIR="$D" COVERAGE_NAME='coverage.cobertura*.xml'

expect dotnet-warnings "51/51 tests · 🟡 76.5 % lines · 3 warnings" warning \
  STEPS=$'restore|0|false|0\nbuild|0|false|0' WARNINGS="1 2 " TESTS_FORMAT=trx TESTS_PATH="$D" \
  COVERAGE_DIR="$D" COVERAGE_NAME='coverage.cobertura*.xml'

expect build-errors "2 build errors · 1 warning" failure \
  STEPS=$'restore|0|false|0\nbuild|2|false|1' WARNINGS="1"

expect unrecognised "build exit 137 (killed)" failure \
  STEPS=$'restore|0|false|0\nbuild|0|true|137'

expect one-error "1 lint error" failure STEPS=$'lint|1||1'

F="$WORK/dotnet-failing"
trx "$F/tests/Api.Tests" 51 47 3 1
expect tests-failed "4/51 tests failed" failure TESTS_FORMAT=trx TESTS_PATH="$F"

S="$WORK/dotnet-skipped"
trx "$S/tests/Api.Tests" 51 49 0 0 2
expect tests-skipped "49/51 tests (2 skipped)" success TESTS_FORMAT=trx TESTS_PATH="$S"

N="$WORK/node"
mkdir -p "$N/coverage"
echo '{"numTotalTests":129,"numPassedTests":126,"numFailedTests":3,"numPendingTests":0,"numTodoTests":0,"success":false}' > "$N/coverage/json-report.json"
cobertura "$N/coverage/cobertura-coverage.xml" 715 1000
expect node-failing "3/129 tests failed · 🟡 71.5 % lines" failure \
  STEPS=$'typecheck|0|false|0\nbuild|0|false|0\nlint|0|false|0' TESTS_FORMAT=jest-json \
  TESTS_PATH="$N/coverage/json-report.json" COVERAGE_DIR="$N/coverage" COVERAGE_NAME=cobertura-coverage.xml

expect tests-crashed "tests failed" failure TESTS_FORMAT=jest-json TESTS_PATH="$WORK/none.json" TESTS_FAILED=true

expect free-text "npm ci failed" failure FAILURES=$'\nnpm ci failed\n'

G="$WORK/git-status.md"
printf '## ❌ Changes in files after restore and build\n' > "$G"
expect git-status "files changed by the build" failure GIT_STATUS_FILE="$G"

R="$WORK/rate-only"
mkdir -p "$R"
printf '<coverage line-rate="0.842" branch-rate="0">\n</coverage>\n' > "$R/cobertura-coverage.xml"
expect rate-only "🟢 84.2 % lines" success COVERAGE_DIR="$R" COVERAGE_NAME=cobertura-coverage.xml

L="$WORK/low"
cobertura "$L/cobertura-coverage.xml" 399 1000
expect coverage-red "🔴 39.9 % lines" success COVERAGE_DIR="$L" COVERAGE_NAME=cobertura-coverage.xml
expect coverage-thresholds "🟢 39.9 % lines" success COVERAGE_DIR="$L" COVERAGE_NAME=cobertura-coverage.xml COVERAGE_THRESHOLDS="20 30"
expect coverage-bad-thresholds "🔴 39.9 % lines" success COVERAGE_DIR="$L" COVERAGE_NAME=cobertura-coverage.xml COVERAGE_THRESHOLDS="x"
G80="$WORK/edge"
cobertura "$G80/cobertura-coverage.xml" 800 1000
expect coverage-edge "🟢 80.0 % lines" success COVERAGE_DIR="$G80" COVERAGE_NAME=cobertura-coverage.xml

expect nothing "" success

expect no-files "" success TESTS_FORMAT=trx TESTS_PATH="$WORK/empty-dir" COVERAGE_DIR="$WORK/empty-dir" COVERAGE_NAME='*.xml'

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
