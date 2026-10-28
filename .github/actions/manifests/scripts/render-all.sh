#!/usr/bin/env bash
# Renders every entry of $RENDERS (one `<out-path>=<deploy-dir>[,<component>]` per line) from
# <src-root> into <out-dir>, and lists the rendered out-paths in <list-file>.
#
#   render-all.sh <src-root> <out-dir> <list-file> [validate|best-effort]
#
# validate:    also run kubeconform ($KUBECONFORM_ARGS) on each render; any failure fails.
# best-effort: a render that fails is skipped (used for the PR base, whose tree or contract
#              isn't this PR's problem).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$1"
outdir="$2"
list="$3"
mode="${4:-validate}"

read -ra kubeconform_args <<< "${KUBECONFORM_ARGS:--strict -summary}"
rm -rf "$outdir"
mkdir -p "$outdir"
: > "$list"

status=0
while IFS= read -r line; do
  line="$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  [ -n "$line" ] || continue
  if [[ "$line" != *=* ]]; then
    echo "::error::renders entry '$line' must be <out-path>=<deploy-dir>[,<component>]"
    exit 1
  fi
  out="${line%%=*}"
  rest="${line#*=}"
  dir="${rest%%,*}"
  component=""
  if [[ "$rest" == *,* ]]; then
    component="${rest#*,}"
  fi
  case "$out" in
    /* | *..* | "")
      echo "::error::renders out-path '$out' must be relative and stay inside the artifact"
      exit 1
      ;;
  esac
  echo "$out" >> "$list"

  if [ ! -d "$root/$dir" ]; then
    if [ "$mode" = best-effort ]; then
      echo "No $dir in $root; treating it as empty."
      continue
    fi
    echo "::error::renders directory '$dir' does not exist"
    exit 1
  fi

  echo "::group::Render $out from $dir${component:+ + $component}"
  if "$here/render-manifests.sh" "$root/$dir" "$outdir/$out" "$component"; then
    if [ "$mode" = validate ] && ! kubeconform "${kubeconform_args[@]}" "$outdir/$out"; then
      status=1
    fi
  elif [ "$mode" = best-effort ]; then
    echo "Render of $dir failed; treating it as empty."
    rm -f "$outdir/$out"
  else
    status=1
  fi
  echo "::endgroup::"
done <<< "$RENDERS"

if [ ! -s "$list" ]; then
  echo "::error::renders is empty"
  exit 1
fi
exit "$status"
