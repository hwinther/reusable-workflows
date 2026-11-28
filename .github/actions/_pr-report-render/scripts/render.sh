#!/usr/bin/env bash
# Renders the combined PR report from the pr-report-* artifacts of a commit's workflow runs.
# Env:
#   REPORTS_DIR        runs/<run_id>/<artifact>/{status.json,report.md}
#   SHA                the commit the report is for
#   IN_PROGRESS        workflows still running for SHA, one name per line
#   RUNS_URL           e.g. https://github.com/o/r/actions/runs (a section links to its run)
#   AGGREGATOR_URL     the run that rendered this (footer)
#   OUT_MD             where to write the markdown
#   MAX_SECTION_CHARS  cap per section body (default 12000)
#   NOW                timestamp for the footer (default: current UTC time)
set -euo pipefail
export LC_ALL=C.UTF-8

MAX_SECTION_CHARS="${MAX_SECTION_CHARS:-12000}"
NOW="${NOW:-$(date -u '+%Y-%m-%d %H:%M UTC')}"
work="$(mktemp -d "${RUNNER_TEMP:-/tmp}/pr-report.XXXXXX")"
trap 'rm -rf "$work"' EXIT

# One JSON object per valid status.json; a broken or foreign file is skipped, not fatal.
: > "$work/entries"
for f in "$REPORTS_DIR"/runs/*/*/status.json; do
  [ -f "$f" ] || continue
  dir="$(dirname "$f")"
  run_id="$(basename "$(dirname "$dir")")"
  [[ "$run_id" =~ ^[0-9]+$ ]] || continue
  jq -c --argjson run "$run_id" --arg dir "$dir" '
    select(type == "object" and (.id | type) == "string" and (.id | length) > 0)
    | { id, run: $run, dir: $dir,
        title: ((.title // .id) | tostring),
        status: ((.status // "neutral") | tostring),
        summary: ((.summary // "") | tostring),
        order: ((.order // 50) | tonumber? // 50) }' "$f" > "$work/one" 2>/dev/null || : > "$work/one"
  # Staged, then appended: jq.exe on MSYS doesn't honour O_APPEND when redirected with >>.
  cat "$work/one" >> "$work/entries"
done

# A section re-uploaded by a later run (a re-run, a second workflow) wins; then sort for display.
jq -s 'group_by(.id) | map(max_by(.run)) | sort_by(.order, .title)' "$work/entries" > "$work/sections.json"

emoji() {
  case "$1" in
    success) echo "✅" ;; failure) echo "❌" ;; warning) echo "⚠️" ;; cancelled) echo "⏹️" ;;
    skipped) echo "⏭️" ;; *) echo "ℹ️" ;;
  esac
}
word() {
  case "$1" in
    success) echo "passed" ;; failure) echo "failed" ;; warning) echo "warnings" ;; cancelled) echo "cancelled" ;;
    skipped) echo "skipped" ;; *) echo "" ;;
  esac
}
# A table cell: one line, pipes escaped.
cell() { printf '%s' "$1" | tr '\r\n' '  ' | sed 's/|/\\|/g'; }

# Body of one section, capped at a line break with any open code fence closed.
section_body() {
  local file="$1" run="$2" body
  [ -s "$file" ] || { echo "_No details._"; return; }
  # Headings two levels down, so a section's "## ✅ Build succeeded" stays under the report's own.
  body="$(sed -E 's/^(#{1,4}) /\1## /' "$file")"
  if [ "${#body}" -gt "$MAX_SECTION_CHARS" ]; then
    body="${body:0:$MAX_SECTION_CHARS}"
    body="${body%$'\n'*}"
    if [ $(( $(printf '%s\n' "$body" | grep -c '^[[:space:]]*```' || true) % 2 )) -eq 1 ]; then
      body="${body}"$'\n''```'
    fi
    body="${body}"$'\n\n'"… cut here; the full report is in the job summary of [the run](${RUNS_URL}/${run})."
  fi
  printf '%s\n' "$body"
}

count="$(jq 'length' "$work/sections.json")"
{
  echo "## 🧾 PR status — \`${SHA:0:7}\`"
  echo ""
  if [ "$count" -eq 0 ] && [ -z "$(printf '%s' "${IN_PROGRESS:-}" | tr -d '[:space:]')" ]; then
    echo "No reports for this commit yet."
  else
    echo "| Check | Result | Run |"
    echo "|---|---|---|"
    for i in $(seq 0 $((count - 1))); do
      s="$(jq -c ".[$i]" "$work/sections.json")"
      status="$(jq -r '.status' <<< "$s")"
      title="$(jq -r '.title' <<< "$s")"
      summary="$(jq -r '.summary' <<< "$s")"
      run="$(jq -r '.run' <<< "$s")"
      result="$(word "$status")"
      # A warning's summary already says what the warnings are ("… · 3 warnings").
      if [ -n "$summary" ] && [ "$status" = "warning" ]; then
        result="$summary"
      elif [ -n "$summary" ]; then
        result="${result:+$result · }${summary}"
      fi
      echo "| $(emoji "$status") $(cell "$title") | $(cell "${result:-–}") | [run](${RUNS_URL}/${run}) |"
    done
    while IFS= read -r wf; do
      [ -n "$(printf '%s' "$wf" | tr -d '[:space:]')" ] || continue
      echo "| ⏳ $(cell "$wf") | running | |"
    done <<< "${IN_PROGRESS:-}"
    for i in $(seq 0 $((count - 1))); do
      s="$(jq -c ".[$i]" "$work/sections.json")"
      status="$(jq -r '.status' <<< "$s")"
      open=""
      case "$status" in success|skipped|neutral) ;; *) open=" open" ;; esac
      echo ""
      echo "<details${open}><summary>$(emoji "$status") $(jq -r '.title' <<< "$s" | sed 's/</\&lt;/g')</summary>"
      echo ""
      section_body "$(jq -r '.dir' <<< "$s")/report.md" "$(jq -r '.run' <<< "$s")"
      echo ""
      echo "</details>"
    done
  fi
  echo ""
  echo "<sub>Updated ${NOW}${AGGREGATOR_URL:+ by [pr-report](${AGGREGATOR_URL})}.</sub>"
} > "$OUT_MD"
