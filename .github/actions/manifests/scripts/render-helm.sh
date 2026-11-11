#!/usr/bin/env bash
# Renders one Helm chart directory into a single manifest file.
#
#   render-helm.sh <chart-dir> <out-file> [values-file ...]
#
# Values files are relative to the chart dir and applied in order. The chart's dependencies are
# fetched with `helm dependency update` first; one from a private or OCI repository needs a
# `helm registry login` (or `helm repo add`) earlier in the caller's job. The output is what
# `helm template` prints, unchanged: in push mode it is what gets deployed.
#
# RELEASE_NAME (env) sets the release name (default: the chart dir's name), HELM_NAMESPACE the
# namespace (default: helm's own) and HELM_KUBE_VERSION --kube-version. There is no contract
# check: Helm renders have no Flux ${VAR} placeholders of their own.
set -euo pipefail

chart="$1"
out="$2"
shift 2

if [ ! -f "$chart/Chart.yaml" ]; then
  echo "::error::$chart is not a Helm chart (no Chart.yaml)"
  exit 1
fi

args=()
for values in "$@"; do
  if [ ! -f "$chart/$values" ]; then
    echo "::error::values file $values not found in $chart"
    exit 1
  fi
  args+=(-f "$chart/$values")
done
if [ -n "${HELM_NAMESPACE:-}" ]; then
  args+=(--namespace "$HELM_NAMESPACE")
fi
if [ -n "${HELM_KUBE_VERSION:-}" ]; then
  args+=(--kube-version "$HELM_KUBE_VERSION")
fi

helm dependency update "$chart" > /dev/null
mkdir -p "$(dirname "$out")"
helm template "${RELEASE_NAME:-$(basename "$(cd "$chart" && pwd)")}" "$chart" "${args[@]}" > "$out"
