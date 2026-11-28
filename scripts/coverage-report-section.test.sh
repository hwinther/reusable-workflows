#!/usr/bin/env bash
# Tests for .github/actions/_coverage-report-section/scripts/parse.sh.
# Run: bash scripts/coverage-report-section.test.sh (non-zero exit if a case fails).
set -uo pipefail
export LC_ALL=C.UTF-8

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/.github/actions/_coverage-report-section/scripts/parse.sh"
WORK="$REPO_ROOT/.test-work/coverage-report-section"
rm -rf "$WORK"
mkdir -p "$WORK"

PASS=0
FAIL=0

# expect <case> <markdown> <expected summary> [VAR=value ...]
expect() {
  local name="$1" md="$2" want="$3"
  shift 3
  printf '%s' "$md" > "$WORK/$name.md"
  : > "$WORK/$name.out"
  env GITHUB_OUTPUT="$WORK/$name.out" MARKDOWN_FILE="$WORK/$name.md" "$@" bash "$SCRIPT" > /dev/null 2>&1
  local got
  got="$(sed -n 's/^summary=//p' "$WORK/$name.out")"
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "❌ $name"
    echo "    want: $want"
    echo "    got:  $got"
  fi
}

table() { # table <unit label> <unit %> <e2e %> <combined %>
  cat <<MD
### Coverage: unit + e2e (lines)

| Suite | Lines covered | % |
| --- | ---: | ---: |
| $1 | 715 / 1000 | $2 |
| E2E (Playwright) | 540 / 1000 | $3 |
| **Combined** | 823 / 1000 | $4 |

_Approximate: istanbul counts statement lines, …_

### Where e2e adds the most

| File | Lines added by e2e | Unit | Combined |
| --- | ---: | ---: | ---: |
| \`app/routes/home.tsx\` | 40 | 10.0% | 90.0% |
MD
}

expect full "$(table Unit 71.5% 54.0% 82.3%)" \
  "unit 🟡 71.5 % · e2e 🟡 54.0 % · combined 🟢 82.3 % (+10.8 from e2e)"
expect custom-label "$(table 'Unit (vitest)' 35.0% 20.0% 41.0%)" \
  "unit 🔴 35.0 % · e2e 🔴 20.0 % · combined 🟡 41.0 % (+6.0 from e2e)"
expect no-unit "$(table Unit n/a 54.0% 54.0%)" \
  "e2e 🟡 54.0 % · combined 🟡 54.0 %"
expect no-e2e "$(table Unit 71.5% n/a 71.5%)" \
  "unit 🟡 71.5 % · combined 🟡 71.5 % (+0.0 from e2e)"
expect thresholds "$(table Unit 71.5% 54.0% 82.3%)" \
  "unit 🟢 71.5 % · e2e 🟡 54.0 % · combined 🟢 82.3 % (+10.8 from e2e)" COVERAGE_THRESHOLDS="50 70"
expect no-table "Nothing to see here" ""
expect file-table-ignored "$(printf '| Suite | Lines covered | %% |\n| --- | ---: | ---: |\n| Unit | 1 / 2 | 50.0%% |\n| E2E (Playwright) | 1 / 2 | 50.0%% |\n| **Combined** | 2 / 2 | 100.0%% |\n\n| File | Lines added by e2e | Unit | Combined |\n| --- | ---: | ---: | ---: |\n| x | 1 | 1.0%% | 99.0%% |\n')" \
  "unit 🟡 50.0 % · e2e 🟡 50.0 % · combined 🟢 100.0 % (+50.0 from e2e)"

echo ""
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$FAIL" -eq 0 ]
