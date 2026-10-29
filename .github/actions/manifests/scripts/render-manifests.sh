#!/usr/bin/env bash
# Renders one kustomize directory into a single manifest file and checks the variable contract.
#
#   render-manifests.sh <deploy-dir> <out-file> [component]
#
# IMAGES (env, optional): newline-separated image refs, registry/name:tag@sha256:..., pinned
# into the render through a kustomize `images:` entry each. Leave it empty to keep the
# directory's placeholder tags (PR diffs). component is a path under deploy-dir, e.g.
# components/preview, added as a kustomize Component.
#
# Contract check: the rendered output may only contain ${VAR}s (without a default) that the
# contract README documents as `VAR`. Flux substitutes an undefined variable with an empty
# string instead of failing, so an undocumented one is a silent misconfiguration waiting to
# happen. The README is the nearest README.md at or above deploy-dir, stopping below the
# current directory (the repo root's README is not a contract). CONTRACT=false (env) skips it,
# for directories that aren't an artifact contract (a cluster repo's Flux paths).
set -euo pipefail

src="$(cd "$1" && pwd)"
out="$2"
component="${3:-}"
root="$(pwd)"

mkdir -p "$(dirname "$out")"
# With nothing to add, render the directory in place: a cluster repo's kustomizations reference
# shared bases outside the directory (../../bases/x), which a copy would cut off.
if [ -z "$(printf '%s' "${IMAGES:-}" | tr -d '[:space:]')" ] && [ -z "$component" ]; then
  kubectl kustomize "$src" > "$out"
else
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  mkdir -p "$work/overlay"
  # Copy instead of referencing the source by path: kustomize resolves `resources:` relative to
  # the overlay, and an absolute path breaks on some platforms.
  cp -r "$src" "$work/base"

  {
    echo "apiVersion: kustomize.config.k8s.io/v1beta1"
    echo "kind: Kustomization"
    echo "resources:"
    echo "- ../base"
    if [ -n "${IMAGES:-}" ]; then
      echo "images:"
      while IFS= read -r image; do
        image="$(printf '%s' "$image" | tr -d '[:space:]')"
        [ -n "$image" ] || continue
        case "$image" in
          *:*@sha256:*) ;;
          *)
            echo "::error::image '$image' must be registry/name:tag@sha256:digest" >&2
            exit 1
            ;;
        esac
        ref="${image%@*}"
        echo "- name: ${ref%:*}"
        echo "  newTag: ${ref##*:}"
        echo "  digest: ${image#*@}"
      done <<< "$IMAGES"
    fi
    if [ -n "$component" ]; then
      echo "components:"
      echo "- ../base/$component"
    fi
  } > "$work/overlay/kustomization.yaml"

  kubectl kustomize "$work/overlay" > "$out"
fi

if [ "${CONTRACT:-true}" = false ]; then
  exit 0
fi

readme=""
dir="$src"
while [ "$dir" != "$root" ] && [ "$dir" != "/" ]; do
  if [ -f "$dir/README.md" ]; then
    readme="$dir/README.md"
    break
  fi
  dir="$(dirname "$dir")"
done

missing=0
for var in $(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "$out" | tr -d '${}' | sort -u); do
  if [ -z "$readme" ] || ! grep -q "\`$var\`" "$readme"; then
    echo "::error::\${$var} in $1 has no default and is not documented in ${readme:-a README.md next to it}"
    missing=1
  fi
done
exit "$missing"
