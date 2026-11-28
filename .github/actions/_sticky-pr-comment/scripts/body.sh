#!/usr/bin/env bash
# Builds the comment body for ../action.yml and prints what to do with it: "post" (BODY_FILE
# written) or "delete" (nothing to say, and the caller asked for an empty comment to go away).
# Env: MARKER, CONTENT, FALLBACK_CONTENT, DELETE_WHEN_EMPTY, MAX_CHARS, RUN_URL, BODY_FILE.
set -euo pipefail
# Count and cut characters, not bytes (GitHub's limit is in characters).
export LC_ALL=C.UTF-8

is_blank() { [ -z "$(printf '%s' "$1" | tr -d '[:space:]')" ]; }

content="${CONTENT:-}"
if is_blank "$content"; then
  content="${FALLBACK_CONTENT:-}"
fi
if is_blank "$content" && [ "${DELETE_WHEN_EMPTY:-false}" = "true" ]; then
  echo "delete"
  exit 0
fi

# GitHub rejects comments over 65536 characters (422), which left the previous run's comment in
# place. Cut at a line break below the limit, close an open code fence, and say where the rest is.
max="${MAX_CHARS:-60000}"
body="${MARKER}"$'\n'"${content}"
if [ "${#body}" -gt "$max" ]; then
  total="${#body}"
  body="${body:0:$((max - 400))}"
  body="${body%$'\n'*}"
  fences="$(printf '%s\n' "$body" | grep -c '^[[:space:]]*```' || true)"
  if [ $((fences % 2)) -eq 1 ]; then
    body="${body}"$'\n''```'
  fi
  where="the job summary"
  [ -n "${RUN_URL:-}" ] && where="the job summary of [the workflow run](${RUN_URL})"
  body="${body}"$'\n\n'"… truncated: the report was ${total} characters, over GitHub's comment limit. The full report is in ${where}."
fi
printf '%s' "$body" > "$BODY_FILE"
echo "post"
