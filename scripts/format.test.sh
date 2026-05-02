#!/usr/bin/env bash
# Tests for .github/actions/_format-output/scripts/format.sh.
#
# Each case is a directory under scripts/format.test/cases/<name>/. The runner stages
# the case files into a tempdir, runs format.sh with managed paths, and diffs the
# resulting markdown / annotations / outputs against the case's expected.* files.
#
# Per-case files (all optional unless noted):
#   env.sh             — sourced before format.sh runs. MUST set FORMAT and may set
#                        ERROR_HEADER, WARNING_HEADER, SUCCESS_MESSAGE,
#                        MAX_WARNINGS_INLINE, PATH_STRIP.
#   errors             — line-based input passed to format.sh as ERRORS_FILE
#                        (auto-detected if env.sh doesn't set ERRORS_FILE).
#   warnings           — same, for WARNINGS_FILE.
#   eslint.json        — auto-mapped to ERRORS_FILE when present (eslint-json kind).
#   expected.md        — required. Diffed against actual generated markdown.
#   expected.stdout    — optional. Diffed against captured GitHub annotations.
#   expected.outputs   — optional. Diffed against captured GITHUB_OUTPUT lines.
#
# Run: bash scripts/format.test.sh
# Exit code is non-zero if any case fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORMAT_SCRIPT="$REPO_ROOT/.github/actions/_format-output/scripts/format.sh"
CASES_DIR="$REPO_ROOT/scripts/format.test/cases"
# Stage work dirs under the repo so native Windows binaries (jq.exe on MSYS) can read
# the paths. mktemp's default `/tmp` works on Linux but is an MSYS-internal mount that
# Windows-native processes can't access.
WORK_ROOT="$REPO_ROOT/.test-work"
mkdir -p "$WORK_ROOT"

if [ ! -f "$FORMAT_SCRIPT" ]; then
  echo "format.sh not found at $FORMAT_SCRIPT" >&2
  exit 2
fi
if [ ! -d "$CASES_DIR" ]; then
  echo "No cases directory at $CASES_DIR" >&2
  exit 2
fi

# Filter cases via the first positional arg (substring match) for focused debugging.
FILTER="${1:-}"

PASS=0
FAIL=0
SKIP=0
FAILED_CASES=()

run_case() {
  local case_dir="$1"
  local case_name
  case_name=$(basename "$case_dir")

  if [ -n "$FILTER" ] && [[ "$case_name" != *"$FILTER"* ]]; then
    SKIP=$((SKIP+1))
    return 0
  fi

  echo "=== $case_name ==="

  local work
  work=$(mktemp -d -p "$WORK_ROOT")
  cp -r "$case_dir"/. "$work/"

  # Reset state in this subshell-ish scope. Variables intentionally local so they
  # don't leak between cases.
  unset FORMAT ERRORS_FILE WARNINGS_FILE OUT_MD ERROR_HEADER WARNING_HEADER \
        SUCCESS_MESSAGE MAX_WARNINGS_INLINE PATH_STRIP

  local out_md="$work/actual.md"
  local out_outputs="$work/actual.outputs"
  local out_stdout="$work/actual.stdout"
  local out_stderr="$work/actual.stderr"
  : > "$out_md"
  : > "$out_outputs"

  if [ -f "$work/env.sh" ]; then
    # shellcheck disable=SC1091
    . "$work/env.sh"
  fi

  if [ -z "${FORMAT:-}" ]; then
    echo "  ❌ env.sh did not set FORMAT"
    rm -rf "$work"
    FAIL=$((FAIL+1)); FAILED_CASES+=("$case_name")
    return 1
  fi

  # Auto-map common file names.
  if [ -z "${ERRORS_FILE:-}" ]; then
    if [ -f "$work/errors" ]; then ERRORS_FILE="$work/errors"; fi
    if [ -f "$work/eslint.json" ]; then ERRORS_FILE="$work/eslint.json"; fi
  fi
  if [ -z "${WARNINGS_FILE:-}" ] && [ -f "$work/warnings" ]; then
    WARNINGS_FILE="$work/warnings"
  fi

  OUT_MD="$out_md"
  GITHUB_OUTPUT="$out_outputs"

  export FORMAT OUT_MD GITHUB_OUTPUT
  [ -n "${ERRORS_FILE:-}" ] && export ERRORS_FILE
  [ -n "${WARNINGS_FILE:-}" ] && export WARNINGS_FILE
  [ -n "${ERROR_HEADER:-}" ] && export ERROR_HEADER
  [ -n "${WARNING_HEADER:-}" ] && export WARNING_HEADER
  [ -n "${SUCCESS_MESSAGE:-}" ] && export SUCCESS_MESSAGE
  [ -n "${MAX_WARNINGS_INLINE:-}" ] && export MAX_WARNINGS_INLINE
  [ -n "${PATH_STRIP:-}" ] && export PATH_STRIP

  bash "$FORMAT_SCRIPT" > "$out_stdout" 2> "$out_stderr"
  local rc=$?

  local case_failed=0

  if [ "$rc" -ne 0 ]; then
    echo "  ❌ format.sh exited $rc"
    echo "    stderr:"
    sed 's/^/      /' "$out_stderr"
    case_failed=1
  fi

  for kind in md stdout outputs; do
    local actual="$work/actual.$kind"
    local expected="$work/expected.$kind"
    if [ -f "$expected" ]; then
      if ! diff -u "$expected" "$actual" > "$work/diff.$kind" 2>&1; then
        echo "  ❌ $kind differs:"
        sed 's/^/    /' "$work/diff.$kind"
        case_failed=1
      fi
    fi
  done

  if [ "$case_failed" -eq 0 ]; then
    echo "  ✅ pass"
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1)); FAILED_CASES+=("$case_name")
  fi

  rm -rf "$work"
}

shopt -s nullglob
for case_dir in "$CASES_DIR"/*/; do
  run_case "$case_dir"
done
shopt -u nullglob

echo
echo "=== Summary ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"
[ "$SKIP" -gt 0 ] && echo "Skipped (filter): $SKIP"
if [ "$FAIL" -gt 0 ]; then
  echo "Failed cases:"
  for c in "${FAILED_CASES[@]}"; do
    echo "  - $c"
  done
  exit 1
fi
