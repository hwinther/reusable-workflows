#!/usr/bin/env bash
# Internal helper invoked by .github/actions/_grype-summary/action.yml.
# Parses a Grype SARIF file and renders a markdown summary to $OUT_MD.
#
# Env contract (all set by the wrapping action):
#   SARIF_FILE          — path to grype-results.sarif
#   OUT_MD              — destination markdown file
#   CATEGORY            — Code Scanning category (display + link query)
#   TOP_N               — cap on findings rendered inline (default 20)
#   GITHUB_SERVER_URL, GITHUB_REPOSITORY, BRANCH — for the deep link

set -uo pipefail

SARIF_FILE="${SARIF_FILE:?SARIF_FILE is required}"
OUT_MD="${OUT_MD:?OUT_MD is required}"
CATEGORY="${CATEGORY:-}"
TOP_N="${TOP_N:-20}"
GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
BRANCH="${BRANCH:-}"

mkdir -p "$(dirname "$OUT_MD")"

# Build a Code Scanning deep link if we have enough context. The query mirrors the
# previous inline step so the alert page filters to this branch's open alerts.
LINK=""
if [ -n "$GITHUB_REPOSITORY" ] && [ -n "$BRANCH" ]; then
  ENC_QUERY=$(printf 'is:open branch:%s ' "$BRANCH" | jq -Rr @uri)
  LINK="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/security/code-scanning?query=${ENC_QUERY}"
fi

write_link_footer() {
  if [ -n "$LINK" ]; then
    echo "" >> "$OUT_MD"
    if [ -n "$CATEGORY" ]; then
      echo "[Open Code Scanning alerts for branch \`${BRANCH}\`](${LINK}) (SARIF category \`${CATEGORY}\`; alerts can take a moment to appear after upload.)" >> "$OUT_MD"
    else
      echo "[Open Code Scanning alerts for branch \`${BRANCH}\`](${LINK}) (alerts can take a moment to appear after upload.)" >> "$OUT_MD"
    fi
  fi
}

if [ ! -f "$SARIF_FILE" ]; then
  {
    echo "### 🛡️ Grype vulnerability scan"
    echo ""
    echo "_No SARIF file found at \`${SARIF_FILE}\`._"
  } > "$OUT_MD"
  write_link_footer
  exit 0
fi

TOTAL=$(jq '[.runs[].results[]?] | length' "$SARIF_FILE" 2>/dev/null || echo 0)

if [ "$TOTAL" -eq 0 ]; then
  {
    echo "### 🛡️ Grype vulnerability scan"
    echo ""
    echo "✅ No vulnerabilities reported."
  } > "$OUT_MD"
  write_link_footer
  exit 0
fi

# Per-band counts. security-severity is on the rule (CVSS numeric); we look it up by ruleId.
COUNTS_CSV=$(jq -r '
  def band(s):
    if s >= 9.0 then "critical"
    elif s >= 7.0 then "high"
    elif s >= 4.0 then "medium"
    elif s > 0.0 then "low"
    else "unknown" end;
  .runs[0] as $run
  | ($run.tool.driver.rules // []) as $rules
  | ($rules
      | map({key: .id, value: ((.properties["security-severity"] // "0") | tonumber)})
      | from_entries
    ) as $sev
  | ($run.results // [])
  | map(band($sev[.ruleId] // 0))
  | reduce .[] as $b ({}; .[$b] = ((.[$b] // 0) + 1))
  | [(.critical // 0), (.high // 0), (.medium // 0), (.low // 0), (.unknown // 0)]
  | join(",")
' "$SARIF_FILE" 2>/dev/null || echo "0,0,0,0,0")

IFS=',' read -r CRIT HIGH MED LOW UNK <<< "$COUNTS_CSV"

# Compose summary line: only show bands with non-zero counts.
SEV_BITS=()
[ "${CRIT:-0}" -gt 0 ] && SEV_BITS+=("🔴 ${CRIT} Critical")
[ "${HIGH:-0}" -gt 0 ] && SEV_BITS+=("🟠 ${HIGH} High")
[ "${MED:-0}" -gt 0 ]  && SEV_BITS+=("🟡 ${MED} Medium")
[ "${LOW:-0}" -gt 0 ]  && SEV_BITS+=("🔵 ${LOW} Low")
[ "${UNK:-0}" -gt 0 ]  && SEV_BITS+=("❓ ${UNK} Unknown")

if [ ${#SEV_BITS[@]} -gt 0 ]; then
  # bash's "${arr[*]}" with IFS uses only the first IFS char, so we get a comma
  # without the space. Build the joined string explicitly.
  SEV_LINE=$(printf '%s, ' "${SEV_BITS[@]}")
  SEV_LINE="${SEV_LINE%, }"
  SUMMARY_LINE="**${TOTAL} findings:** ${SEV_LINE}"
else
  SUMMARY_LINE="**${TOTAL} findings**"
fi

# Top N rows, sorted by descending severity score. Pipes/newlines/long lines are
# normalized so the markdown table doesn't blow up on weird messages.
TABLE_CONTENT=$(jq -r --argjson limit "$TOP_N" '
  def emoji(s):
    if s >= 9.0 then "🔴 Critical"
    elif s >= 7.0 then "🟠 High"
    elif s >= 4.0 then "🟡 Medium"
    elif s > 0.0 then "🔵 Low"
    else "❓ Unknown" end;
  .runs[0] as $run
  | ($run.tool.driver.rules // []) as $rules
  | ($rules
      | map({key: .id, value: ((.properties["security-severity"] // "0") | tonumber)})
      | from_entries
    ) as $sev
  | ($run.results // [])
  | map({
      rule_id: .ruleId,
      score: ($sev[.ruleId] // 0),
      msg: (.message.text // ""),
      location: (.locations[0].physicalLocation.artifactLocation.uri // "")
    })
  | sort_by(-.score)
  | .[0:$limit]
  | .[]
  | "| " + emoji(.score)
    + " | " + (.score | tostring)
    + " | " + .rule_id
    + " | " + (.location | gsub("[|]"; "&#124;"))
    + " | " + (.msg | gsub("\n"; " ") | gsub("[|]"; "&#124;") | .[0:140])
    + " |"
' "$SARIF_FILE" 2>/dev/null || true)

SHOWN=0
if [ -n "$TABLE_CONTENT" ]; then
  SHOWN=$(printf '%s\n' "$TABLE_CONTENT" | grep -c '^|' || true)
  SHOWN=${SHOWN:-0}
fi

{
  echo "### 🛡️ Grype vulnerability scan"
  echo ""
  echo "$SUMMARY_LINE"
  echo ""
  echo "<details>"
  if [ "$SHOWN" -lt "$TOTAL" ]; then
    echo "<summary>Top ${SHOWN} findings (of ${TOTAL}, sorted by severity)</summary>"
  else
    echo "<summary>All ${TOTAL} findings (sorted by severity)</summary>"
  fi
  echo ""
  echo "| Severity | CVSS | ID | Location | Description |"
  echo "|---|---|---|---|---|"
  printf '%s\n' "$TABLE_CONTENT"
  echo ""
  echo "</details>"
} > "$OUT_MD"

write_link_footer
