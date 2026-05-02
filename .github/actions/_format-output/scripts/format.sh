#!/usr/bin/env bash
# Internal helper invoked by .github/actions/_format-output/action.yml.
# Reads pre-extracted error/warning lines (or an ESLint JSON report) and emits
# GitHub Actions annotations + structured markdown for the calling action.
#
# All inputs come in as env vars, set by the composite action wrapper.

set -uo pipefail

FORMAT="${FORMAT:?FORMAT is required}"
OUT_MD="${OUT_MD:?OUT_MD is required}"
ERRORS_FILE="${ERRORS_FILE:-}"
WARNINGS_FILE="${WARNINGS_FILE:-}"
ERROR_HEADER="${ERROR_HEADER:-}"
WARNING_HEADER="${WARNING_HEADER:-}"
SUCCESS_MESSAGE="${SUCCESS_MESSAGE:-}"
MAX_WARNINGS_INLINE="${MAX_WARNINGS_INLINE:-10}"

# PATH_STRIP defaults to GITHUB_WORKSPACE/ when both are set. If neither is, no stripping.
# Without this guard, an unset GITHUB_WORKSPACE would default PATH_STRIP to "/" which would
# obliterate every slash in the output.
if [ -z "${PATH_STRIP:-}" ]; then
  if [ -n "${GITHUB_WORKSPACE:-}" ]; then
    PATH_STRIP="${GITHUB_WORKSPACE}/"
  else
    PATH_STRIP=""
  fi
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

ERROR_COUNT=0
WARNING_COUNT=0

mkdir -p "$(dirname "$OUT_MD")"

# Emit a single GitHub Actions annotation for $1 (line) at severity $2 (error|warning).
emit_annotation() {
  local line="$1"
  local sev="$2"

  case "$FORMAT" in
    ts)
      if [[ $line =~ (.+):([0-9]+):[0-9]+\ -\ (error|warning)\ (.+) ]]; then
        echo "::${sev} file=${BASH_REMATCH[1]},line=${BASH_REMATCH[2]}::${BASH_REMATCH[4]}"
      elif [[ $line =~ (.+)\(([0-9]+),[0-9]+\):\ (error|warning)\ (.+) ]]; then
        echo "::${sev} file=${BASH_REMATCH[1]},line=${BASH_REMATCH[2]}::${BASH_REMATCH[4]}"
      else
        echo "::${sev}::${line}"
      fi
      ;;
    csc)
      if [[ $line =~ (.+)\(([0-9]+),[0-9]+\):\ (error|warning)\ (.+)\ \[(.+)\]$ ]]; then
        echo "::${sev} file=${BASH_REMATCH[1]},line=${BASH_REMATCH[2]}::${BASH_REMATCH[4]}"
      else
        echo "::${sev}::${line}"
      fi
      ;;
    nuget)
      if [[ $line =~ ^(.+)\ :\ (error|warning)\ ([A-Za-z0-9]+):\ (.*)$ ]]; then
        echo "::${sev} file=${BASH_REMATCH[1]}::${BASH_REMATCH[3]}: ${BASH_REMATCH[4]}"
      else
        echo "::${sev}::${line}"
      fi
      ;;
    plain)
      echo "::${sev}::${line}"
      ;;
  esac
}

# Path-strip + bullet-format a line list (file $1, emoji $2) -> stdout.
# Path-strip is a literal substring replacement (not regex) so paths with regex meta-chars work.
format_bullet_list() {
  local source="$1"
  local emoji="$2"
  local stripped="$WORK_DIR/stripped"
  if [ -n "$PATH_STRIP" ]; then
    awk -v p="$PATH_STRIP" '
      {
        out = ""
        rest = $0
        while ((idx = index(rest, p)) > 0) {
          out = out substr(rest, 1, idx-1)
          rest = substr(rest, idx + length(p))
        }
        print out rest
      }
    ' "$source" > "$stripped"
  else
    cp "$source" "$stripped"
  fi
  sed '/^$/d' "$stripped" | sed -e "s/^/- ${emoji} /"
}

count_lines() {
  local f="$1"
  if [ -s "$f" ]; then
    wc -l < "$f" | tr -d ' '
  else
    echo 0
  fi
}

if [ "$FORMAT" = "eslint-json" ]; then
  # ESLint --format json: array of file objects, each with .messages[] (severity 1=warn, 2=error).
  if [ -z "$ERRORS_FILE" ] || [ ! -s "$ERRORS_FILE" ]; then
    [ -n "$SUCCESS_MESSAGE" ] && echo "$SUCCESS_MESSAGE" > "$OUT_MD" || : > "$OUT_MD"
  else
    ERROR_COUNT=$(jq '[.[].messages[]? | select(.severity == 2)] | length' "$ERRORS_FILE" 2>/dev/null || echo 0)
    WARNING_COUNT=$(jq '[.[].messages[]? | select(.severity == 1)] | length' "$ERRORS_FILE" 2>/dev/null || echo 0)

    # Annotations (path stripped via ltrimstr — literal, not regex).
    jq -r --arg strip "$PATH_STRIP" '
      .[] | select(.messages | length > 0) | .filePath as $f
      | .messages[] | select(.severity == 2)
      | "::error file=" + ($f | ltrimstr($strip))
        + ",line=" + (.line | tostring)
        + ",col=" + (.column | tostring)
        + "::" + .message + " (" + (.ruleId // "unknown") + ")"
    ' "$ERRORS_FILE" 2>/dev/null || true

    jq -r --arg strip "$PATH_STRIP" '
      .[] | select(.messages | length > 0) | .filePath as $f
      | .messages[] | select(.severity == 1)
      | "::warning file=" + ($f | ltrimstr($strip))
        + ",line=" + (.line | tostring)
        + ",col=" + (.column | tostring)
        + "::" + .message + " (" + (.ruleId // "unknown") + ")"
    ' "$ERRORS_FILE" 2>/dev/null || true

    if [ "$ERROR_COUNT" -eq 0 ] && [ "$WARNING_COUNT" -eq 0 ]; then
      [ -n "$SUCCESS_MESSAGE" ] && echo "$SUCCESS_MESSAGE" > "$OUT_MD" || : > "$OUT_MD"
    else
      : > "$OUT_MD"
      if [ "$ERROR_COUNT" -gt 0 ]; then
        [ -n "$ERROR_HEADER" ] && echo "$ERROR_HEADER" >> "$OUT_MD"
        # Stage jq output to a temp file then cat it in — some MSYS/cygwin shells don't
        # honor O_APPEND for jq's stdout when redirected directly with `>>`, leading to
        # the markdown being silently truncated.
        jq -r --arg strip "$PATH_STRIP" '
          .[] | select(.messages | length > 0) | .filePath as $f
          | .messages[] | select(.severity == 2)
          | "- ❌ " + ($f | ltrimstr($strip) | sub(".*/"; ""))
            + ":" + (.line | tostring) + ":" + (.column | tostring)
            + " - " + .message + " (" + (.ruleId // "unknown") + ")"
        ' "$ERRORS_FILE" > "$WORK_DIR/eslint-err.md" 2>/dev/null || true
        cat "$WORK_DIR/eslint-err.md" >> "$OUT_MD"
      fi
      if [ "$WARNING_COUNT" -gt 0 ]; then
        [ "$ERROR_COUNT" -gt 0 ] && echo "" >> "$OUT_MD"
        [ -n "$WARNING_HEADER" ] && echo "$WARNING_HEADER" >> "$OUT_MD"
        jq -r --arg strip "$PATH_STRIP" '
          .[] | select(.messages | length > 0) | .filePath as $f
          | .messages[] | select(.severity == 1)
          | "- ⚠️ " + ($f | ltrimstr($strip) | sub(".*/"; ""))
            + ":" + (.line | tostring) + ":" + (.column | tostring)
            + " - " + .message + " (" + (.ruleId // "unknown") + ")"
        ' "$ERRORS_FILE" > "$WORK_DIR/eslint-warn.md" 2>/dev/null || true
        cat "$WORK_DIR/eslint-warn.md" >> "$OUT_MD"
      fi
    fi
  fi
else
  # Line-based formats: ts | csc | nuget | plain
  ERR_TMP="$WORK_DIR/errors"
  WARN_TMP="$WORK_DIR/warnings"
  : > "$ERR_TMP"
  : > "$WARN_TMP"
  [ -n "$ERRORS_FILE" ] && [ -s "$ERRORS_FILE" ] && cp "$ERRORS_FILE" "$ERR_TMP"
  [ -n "$WARNINGS_FILE" ] && [ -s "$WARNINGS_FILE" ] && cp "$WARNINGS_FILE" "$WARN_TMP"

  ERROR_COUNT=$(count_lines "$ERR_TMP")
  WARNING_COUNT=$(count_lines "$WARN_TMP")

  if [ "$ERROR_COUNT" -gt 0 ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      emit_annotation "$line" "error"
    done < "$ERR_TMP"
  fi
  if [ "$WARNING_COUNT" -gt 0 ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      emit_annotation "$line" "warning"
    done < "$WARN_TMP"
  fi

  if [ "$ERROR_COUNT" -eq 0 ]; then
    [ -n "$SUCCESS_MESSAGE" ] && echo "$SUCCESS_MESSAGE" > "$OUT_MD" || : > "$OUT_MD"
  else
    : > "$OUT_MD"
    [ -n "$ERROR_HEADER" ] && echo "$ERROR_HEADER" >> "$OUT_MD"
    format_bullet_list "$ERR_TMP" "❌" >> "$OUT_MD"
  fi

  if [ "$WARNING_COUNT" -gt 0 ]; then
    echo "" >> "$OUT_MD"
    if [ -n "$WARNING_HEADER" ]; then
      # Substitute (N total) placeholder if present so callers can include the count without
      # needing to compute it themselves.
      if [[ "$WARNING_HEADER" == *"(N total)"* ]]; then
        echo "${WARNING_HEADER//(N total)/($WARNING_COUNT total)}" >> "$OUT_MD"
      else
        echo "$WARNING_HEADER" >> "$OUT_MD"
      fi
    fi
    if [ "$WARNING_COUNT" -le "$MAX_WARNINGS_INLINE" ]; then
      format_bullet_list "$WARN_TMP" "⚠️" >> "$OUT_MD"
    else
      head -n "$MAX_WARNINGS_INLINE" "$WARN_TMP" > "$WORK_DIR/warn-head"
      format_bullet_list "$WORK_DIR/warn-head" "⚠️" >> "$OUT_MD"
      echo "" >> "$OUT_MD"
      echo "... and $((WARNING_COUNT - MAX_WARNINGS_INLINE)) more warnings" >> "$OUT_MD"
    fi
  fi
fi

{
  echo "error_count=$ERROR_COUNT"
  echo "warning_count=$WARNING_COUNT"
  if [ "$ERROR_COUNT" -gt 0 ]; then
    echo "failed=true"
  else
    echo "failed=false"
  fi
} >> "$GITHUB_OUTPUT"
