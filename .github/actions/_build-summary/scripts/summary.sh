#!/usr/bin/env bash
# One line summing up a build for the PR report table, e.g.
#   "51/51 tests · 84.2 % lines · 3 warnings"   or   "2 build errors · 3/129 tests failed"
# and a status: failure (something failed), warning (warnings only) or success.
# Env (all optional):
#   STEPS            lines "label|error_count|unrecognised_failed|exit_code" (from the formatters
#                    and _unrecognised-failure)
#   FAILURES         lines of free-text failures, e.g. "npm ci failed"
#   WARNINGS         warning counts, separated by spaces
#   TESTS_FORMAT     trx (TESTS_PATH: a directory searched for */TestResults/*.trx) or jest-json
#                    (TESTS_PATH: the --json report); empty when tests didn't run
#   TESTS_FAILED     true when the test step failed (used when no counts could be read)
#   COVERAGE_DIR     directory searched for Cobertura files named COVERAGE_NAME
#   COVERAGE_NAME    find -name pattern, e.g. coverage.cobertura*.xml
#   GIT_STATUS_FILE  the uncommitted-changes section; a ❌ heading counts as a failure
#   COVERAGE_THRESHOLDS  "red green": coverage below red is 🔴, below green 🟡, else 🟢 (default "40 80")
# Writes summary= and status= to GITHUB_OUTPUT.
set -uo pipefail

parts=()
failed=false

plural() { if [ "$1" -eq 1 ]; then echo "$1 $2"; else echo "$1 ${2}s"; fi; }

# The same colouring as _coverage-report-section. Informational: it doesn't change the status.
read -r COV_RED COV_GREEN _ <<< "${COVERAGE_THRESHOLDS:-40 80}"
[[ "${COV_RED:-}" =~ ^[0-9.]+$ ]] || COV_RED=40
[[ "${COV_GREEN:-}" =~ ^[0-9.]+$ ]] || COV_GREEN=80
cov() {
  awk -v p="$1" -v r="$COV_RED" -v g="$COV_GREEN" \
    'BEGIN { printf "%s %.1f %% lines", (p < r) ? "🔴" : (p < g) ? "🟡" : "🟢", p }'
}

# --- failures of the build steps
while IFS='|' read -r label errors unrecognised code; do
  [ -n "${label// /}" ] || continue
  if [ "${unrecognised:-}" = "true" ]; then
    reason=""
    case "${code:-}" in
      124) reason=" (timed out)" ;; 127) reason=" (command not found)" ;;
      137) reason=" (killed)" ;; 139) reason=" (segfault)" ;;
    esac
    parts+=("${label} exit ${code:-?}${reason}")
    failed=true
  elif [[ "${errors:-}" =~ ^[0-9]+$ ]] && [ "$errors" -gt 0 ]; then
    parts+=("$(plural "$errors" "${label} error")")
    failed=true
  fi
done <<< "${STEPS:-}"

while IFS= read -r line; do
  [ -n "${line// /}" ] || continue
  parts+=("$line")
  failed=true
done <<< "${FAILURES:-}"

if [ -n "${GIT_STATUS_FILE:-}" ] && [ -f "$GIT_STATUS_FILE" ] && grep -q '^## ❌' "$GIT_STATUS_FILE"; then
  parts+=("files changed by the build")
  failed=true
fi

# --- tests
total=""; passed=0; tfailed=0; skipped=0
case "${TESTS_FORMAT:-}" in
  trx)
    while IFS= read -r -d '' f; do
      line="$(grep -oE '<Counters [^>]*>' "$f" | head -n 1)"
      [ -n "$line" ] || continue
      num() { printf '%s' "$line" | grep -oE "[[:space:]]$1=\"[0-9]+\"" | grep -oE '[0-9]+' | head -n 1; }
      t="$(num total)"; p="$(num passed)"; fa="$(num failed)"; er="$(num error)"; ne="$(num notExecuted)"; inc="$(num inconclusive)"
      total=$(( ${total:-0} + ${t:-0} ))
      passed=$(( passed + ${p:-0} ))
      tfailed=$(( tfailed + ${fa:-0} + ${er:-0} ))
      skipped=$(( skipped + ${ne:-0} + ${inc:-0} ))
    done < <(find "${TESTS_PATH:-.}" -path '*/TestResults/*.trx' -print0 2>/dev/null)
    ;;
  jest-json)
    if [ -f "${TESTS_PATH:-}" ] && jq -e 'type == "object"' "$TESTS_PATH" > /dev/null 2>&1; then
      total="$(jq -r '.numTotalTests // 0' "$TESTS_PATH")"
      passed="$(jq -r '.numPassedTests // 0' "$TESTS_PATH")"
      tfailed="$(jq -r '.numFailedTests // 0' "$TESTS_PATH")"
      skipped="$(jq -r '(.numPendingTests // 0) + (.numTodoTests // 0)' "$TESTS_PATH")"
    fi
    ;;
esac
if [ -n "$total" ] && [ "$total" -gt 0 ]; then
  if [ "$tfailed" -gt 0 ]; then
    parts+=("${tfailed}/${total} tests failed")
    failed=true
  elif [ "$skipped" -gt 0 ]; then
    parts+=("${passed}/${total} tests (${skipped} skipped)")
  else
    parts+=("${passed}/${total} tests")
  fi
elif [ "${TESTS_FAILED:-}" = "true" ]; then
  parts+=("tests failed")
  failed=true
fi

# --- line coverage, summed over the files (never an average of rates: projects differ in size)
if [ -n "${COVERAGE_DIR:-}" ] && [ -n "${COVERAGE_NAME:-}" ] && [ -d "$COVERAGE_DIR" ]; then
  covered=0; valid=0; rate=""; files=0
  while IFS= read -r -d '' f; do
    root="$(head -c 4096 "$f" | tr '\n' ' ' | grep -oE '<coverage [^>]*>' | head -n 1)"
    [ -n "$root" ] || continue
    attr() { printf '%s' "$root" | grep -oE "[[:space:]]$1=\"[0-9.]+\"" | grep -oE '[0-9.]+' | head -n 1; }
    c="$(attr lines-covered)"; v="$(attr lines-valid)"
    files=$((files + 1))
    if [[ "$c" =~ ^[0-9]+$ ]] && [[ "$v" =~ ^[0-9]+$ ]]; then
      covered=$((covered + c)); valid=$((valid + v))
    else
      rate="$(attr line-rate)"
    fi
  done < <(find "$COVERAGE_DIR" -name "$COVERAGE_NAME" -not -path '*/node_modules/*' -print0 2>/dev/null)
  if [ "$valid" -gt 0 ]; then
    parts+=("$(cov "$(awk -v c="$covered" -v v="$valid" 'BEGIN { printf "%.4f", 100 * c / v }')")")
  elif [ "$files" -eq 1 ] && [ -n "$rate" ]; then
    parts+=("$(cov "$(awk -v r="$rate" 'BEGIN { printf "%.4f", 100 * r }')")")
  fi
fi

# --- warnings
warnings=0
for w in ${WARNINGS:-}; do
  [[ "$w" =~ ^[0-9]+$ ]] && warnings=$((warnings + w))
done
[ "$warnings" -gt 0 ] && parts+=("$(plural "$warnings" warning)")

summary=""
for p in "${parts[@]}"; do
  summary="${summary:+$summary · }$p"
done
if [ "$failed" = "true" ]; then
  status=failure
elif [ "$warnings" -gt 0 ]; then
  status=warning
else
  status=success
fi
echo "Summary: ${summary:-(none)} [${status}]"
{
  echo "summary=${summary}"
  echo "status=${status}"
} >> "$GITHUB_OUTPUT"
