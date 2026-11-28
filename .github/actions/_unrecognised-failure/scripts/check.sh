#!/usr/bin/env bash
# See ../action.yml. Env: LABEL, EXIT_CODE, RECOGNISED_FAILED, OUTPUT_FILE, OUT_MD, HINT, TAIL_LINES.
set -euo pipefail

TAIL_LINES="${TAIL_LINES:-60}"
if [ -z "${EXIT_CODE:-}" ] || [ "$EXIT_CODE" = "0" ] || [ "${RECOGNISED_FAILED:-}" = "true" ]; then
  echo "failed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

case "$EXIT_CODE" in
  124) reason=", timed out" ;;
  127) reason=", command not found" ;;
  137) reason=", killed (often out of memory)" ;;
  139) reason=", segmentation fault" ;;
  *) reason="" ;;
esac

echo "::error::${LABEL} failed (exit code ${EXIT_CODE}${reason}) and no error line in its output was recognised. The last lines are in the PR comment and the job summary."

tmp="${OUT_MD}.tmp"
{
  echo "## ❌ ${LABEL} failed (exit code ${EXIT_CODE}${reason})"
  echo ""
  if [ -n "${HINT:-}" ]; then
    echo "$HINT"
    echo ""
  fi
  echo "No error line in the output was recognised. The last ${TAIL_LINES} lines:"
  echo ""
  echo '```text'
  if [ -n "${OUTPUT_FILE:-}" ] && [ -s "$OUTPUT_FILE" ]; then
    # Strip colours and break up code fences, so the output can't end the block early.
    sed -e 's/\x1b\[[0-9;]*m//g' -e 's/```/`\xe2\x80\x8b``/g' "$OUTPUT_FILE" | tail -n "$TAIL_LINES" | cut -c 1-400
  else
    echo "(no output)"
  fi
  echo '```'
  # Keep what the formatter wrote (warnings), minus its success line.
  if [ -f "$OUT_MD" ]; then
    rest="$(grep -v '^## ✅' "$OUT_MD" | sed '/./,$!d' || true)"
    if [ -n "$(printf '%s' "$rest" | tr -d '[:space:]')" ]; then
      echo ""
      printf '%s\n' "$rest"
    fi
  fi
} > "$tmp"
mv "$tmp" "$OUT_MD"
echo "failed=true" >> "$GITHUB_OUTPUT"
