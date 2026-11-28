#!/usr/bin/env bash
# Reads the unit / e2e / combined table that @wshno/playwright-config's wshno-coverage-summary
# writes and sums it up for the PR report, e.g.
#   "unit 🟡 71.5 % · e2e 🟡 54.0 % · combined 🟢 82.3 % (+76 lines from e2e)"
# What e2e adds is counted in covered lines (combined minus unit), not as a difference of percentages:
# e2e also loads files the unit tests never import, which grows the combined total, so combined can
# be a lower percentage than unit while e2e still covers more lines.
# The table is "| Suite | Lines covered | % |" with the unit row first (its label is configurable),
# then "E2E (Playwright)" and "**Combined**"; a side without a report reads n/a.
# Env: MARKDOWN_FILE, COVERAGE_THRESHOLDS ("red green", default "40 80"). Writes summary= to
# GITHUB_OUTPUT (empty when there is no table).
set -uo pipefail

read -r COV_RED COV_GREEN _ <<< "${COVERAGE_THRESHOLDS:-40 80}"
[[ "${COV_RED:-}" =~ ^[0-9.]+$ ]] || COV_RED=40
[[ "${COV_GREEN:-}" =~ ^[0-9.]+$ ]] || COV_GREEN=80
# The same colouring as _build-summary.
cov() {
  awk -v p="$1" -v r="$COV_RED" -v g="$COV_GREEN" \
    'BEGIN { printf "%s %.1f %%", (p < r) ? "🔴" : (p < g) ? "🟡" : "🟢", p }'
}

table=""
if [ -f "${MARKDOWN_FILE:-}" ]; then
  table="$(awk '
    /^\| *Suite *\| *Lines covered *\| *% *\|/ { inside = 1; next }
    inside && /^\| *-/ { next }
    inside && /^\|/ { print; next }
    inside { exit }' "$MARKDOWN_FILE")"
fi

# The % column of row $1, without the % sign; empty for n/a or a missing row.
pct_of() {
  local v
  v="$(sed -n "${1}p" <<< "$table" | awk -F'|' '{ gsub(/[ %]/, "", $4); print $4 }')"
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && echo "$v"
}
# The covered lines (the "x" of "x / y") of row $1; empty for n/a or a missing row.
covered_of() {
  local v
  v="$(sed -n "${1}p" <<< "$table" | awk -F'|' '{ split($3, a, "/"); gsub(/ /, "", a[1]); print a[1] }')"
  [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"
}
unit="$(pct_of 1)"
e2e="$(pct_of 2)"
combined="$(pct_of 3)"
unit_covered="$(covered_of 1)"
combined_covered="$(covered_of 3)"

parts=()
[ -n "$unit" ] && parts+=("unit $(cov "$unit")")
[ -n "$e2e" ] && parts+=("e2e $(cov "$e2e")")
if [ -n "$combined" ]; then
  part="combined $(cov "$combined")"
  if [ -n "$unit_covered" ] && [ -n "$combined_covered" ]; then
    added=$((combined_covered - unit_covered))
    if [ "$added" -eq 1 ]; then
      part="${part} (+1 line from e2e)"
    else
      part="${part} (+${added} lines from e2e)"
    fi
  fi
  parts+=("$part")
fi

summary=""
for p in "${parts[@]}"; do
  summary="${summary:+$summary · }$p"
done
echo "Summary: ${summary:-(no coverage table)}"
echo "summary=${summary}" >> "$GITHUB_OUTPUT"
