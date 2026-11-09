#!/usr/bin/env bash
# Renders every entry of $RENDERS (one `<out-path>=<deploy-dir>[,<component>]` per line) from
# <src-root> into <out-dir>, and lists the rendered out-paths in <list-file>.
#
#   render-all.sh <src-root> <out-dir> <list-file> [validate|best-effort]
#
# validate:    also run kubeconform ($KUBECONFORM_ARGS) on each render, unless VALIDATE=false;
#              any failure fails. kubeconform sees a copy with the Flux postBuild variables
#              resolved (see resolve_vars); the render itself keeps them for the cluster.
# best-effort: a render that fails is skipped (used for the PR base, whose tree or contract
#              isn't this PR's problem).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$1"
outdir="$2"
list="$3"
mode="${4:-validate}"

# Same default as action.yml's kubeconform_args (built-in schemas plus the datree CRDs-catalog).
# Kept in a variable: written inline as ${KUBECONFORM_ARGS:-...}, the first `}` of {{.Group}} would
# end the expansion and append the rest of the URL to a set KUBECONFORM_ARGS.
default_kubeconform_args='-strict -summary -schema-location default -schema-location https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
read -ra kubeconform_args <<< "${KUBECONFORM_ARGS:-$default_kubeconform_args}"
rm -rf "$outdir"
mkdir -p "$outdir"
: > "$list"

# The render keeps ${VAR} placeholders for Flux postBuild.substitute. Schemas with patterns (e.g.
# Gateway API HTTPRoute hostnames, parentRefs namespace/sectionName) reject a literal "${APP_HOST}",
# so validate a copy where ${VAR:=default}, ${VAR:-default} and ${VAR=default} become the default,
# and a required ${VAR} becomes a DNS-safe stand-in (APP_HOST -> app-host).
resolve_vars() {
  perl -pe 's/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::?[=-]([^}]*))?\}/defined $2 ? $2 : lc($1 =~ tr|_|-|r)/ge' "$1"
}

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
    if [ "$mode" = validate ] && [ "${VALIDATE:-true}" != false ]; then
      # Outside $outdir (everything in there is pushed as the artifact), and under the render's own
      # file name: kubeconform silently skips files without a .yaml/.yml/.json extension.
      resolved_dir="$(mktemp -d)"
      resolved="$resolved_dir/${out##*/}"
      resolve_vars "$outdir/$out" > "$resolved"
      echo "Validating $out with variables resolved (defaults; required ones as lowercase stand-ins)."
      if ! kubeconform "${kubeconform_args[@]}" "$resolved"; then
        status=1
      fi
      rm -rf "$resolved_dir"
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
