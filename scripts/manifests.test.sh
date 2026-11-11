#!/usr/bin/env bash
# Tests for .github/actions/manifests/scripts (render-all.sh, render-manifests.sh,
# manifest-report.py).
#
# Builds a small fixture app (deploy/ with a Deployment, Service, Ingress, a README contract and
# a preview Component) in a work dir, then checks image pinning, components, the contract check,
# renders-entry validation, best-effort base rendering and the multi-render report. kubeconform
# and dyff are stubbed: this tests our scripts, not those tools. Needs kubectl (kustomize), helm,
# python3 and yq, which the GitHub runners ship.
#
# Run: bash scripts/manifests.test.sh
# Exit code is non-zero if any case fails.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$REPO_ROOT/.github/actions/manifests/scripts"
# Under the repo, not /tmp: native Windows binaries on MSYS can't read /tmp.
WORK="$REPO_ROOT/.test-work/manifests"
rm -rf "$WORK"
mkdir -p "$WORK/bin"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/bin/kubeconform" <<'EOF'
#!/usr/bin/env bash
echo "kubeconform stub: $*"
for a in "$@"; do printf 'argv: [%s]\n' "$a"; done
# Echo the files it was given, so the tests can check what was validated. Like kubeconform, only
# .yaml/.yml/.json files count; anything else is skipped silently.
for f in "$@"; do
  case "$f" in *.yaml | *.yml | *.json) [ -f "$f" ] && sed 's/^/validated: /' "$f" ;; esac
done
exit 0
EOF
cat > "$WORK/bin/dyff" <<'EOF'
#!/usr/bin/env bash
echo "@@ stub dyff @@"
EOF
# Native Windows Python (MSYS runs) can't exec the bash stub; it resolves dyff.cmd instead.
printf '@echo @@ stub dyff @@\r\n' > "$WORK/bin/dyff.cmd"
chmod +x "$WORK/bin/"*
export PATH="$WORK/bin:$PATH"

fail=0
pass() { echo "ok   $1"; }
bad() {
  echo "FAIL $1"
  fail=1
}
expect_grep() { # name, pattern, file
  if grep -q -- "$2" "$3"; then pass "$1"; else bad "$1 (no '$2' in $3)"; fi
}

app="$WORK/app"
mkdir -p "$app/deploy/components/preview"
cat > "$app/deploy/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- workload.yaml
images:
- name: ghcr.io/example/app/api
  newTag: 0.0.0-dev
EOF
cat > "$app/deploy/workload.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
spec:
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      containers:
      - name: api
        image: ghcr.io/example/app/api
        env:
        - name: HOST
          value: "${APP_HOST}"
        - name: MODE
          value: "${APP_MODE:=production}"
        envFrom:
        - secretRef:
            name: app-secrets
---
apiVersion: v1
kind: Service
metadata:
  name: api
spec:
  selector:
    app: api
  ports:
  - port: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: app
spec:
  rules:
  - host: "${APP_HOST}"
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api
            port:
              number: 80
EOF
printf '# deploy\n\n| `APP_HOST` | required |\n' > "$app/deploy/README.md"
cat > "$app/deploy/components/preview/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component
patches:
- target:
    kind: Deployment
    name: api
  patch: |-
    - op: remove
      path: /spec/template/spec/containers/0/envFrom
EOF

cd "$app" || exit 2
digest="sha256:$(printf '%064d' 1)"

# 1. Render with a pinned image and a component; the list file names each out-path.
RENDERS=$'app.yaml=deploy\npreview/app.yaml=deploy,components/preview' \
  IMAGES="ghcr.io/example/app/api:1.2.3@$digest" \
  bash "$SCRIPTS/render-all.sh" . "$WORK/out" "$WORK/list" validate > "$WORK/log" 2>&1
if [ $? -eq 0 ]; then pass "render with images + component"; else bad "render with images + component"; cat "$WORK/log"; fi
expect_grep "image pinned to tag@digest" "image: ghcr.io/example/app/api:1.2.3@$digest" "$WORK/out/app.yaml"
expect_grep "production render keeps envFrom" "envFrom" "$WORK/out/app.yaml"
if grep -q envFrom "$WORK/out/preview/app.yaml"; then bad "component removes envFrom"; else pass "component removes envFrom"; fi
expect_grep "kubeconform ran" "kubeconform stub" "$WORK/log"
catalog='https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
if grep -qxF "argv: [$catalog]" "$WORK/log"; then pass "default args pass the CRDs-catalog URL intact"; else bad "default args pass the CRDs-catalog URL intact"; grep '^argv:' "$WORK/log"; fi
# The action always sets KUBECONFORM_ARGS; a set value must reach kubeconform unchanged.
# Own out dir, list and log, so the checks below still see case 1's output.
KUBECONFORM_ARGS="-strict -schema-location $catalog" RENDERS="app.yaml=deploy" \
  bash "$SCRIPTS/render-all.sh" . "$WORK/out-args" "$WORK/list-args" validate > "$WORK/log-args" 2>&1
if grep -qxF "argv: [$catalog]" "$WORK/log-args" && [ "$(grep -c '^argv:' "$WORK/log-args")" = 4 ]; then
  pass "KUBECONFORM_ARGS reaches kubeconform unchanged"
else
  bad "KUBECONFORM_ARGS reaches kubeconform unchanged"; grep '^argv:' "$WORK/log-args"
fi
expect_grep "validation resolves a default" "validated: .*value: production" "$WORK/log"
expect_grep "validation uses a DNS-safe stand-in for a required var" "validated: .*host: app-host" "$WORK/log"
if grep -q 'validated: .*\${' "$WORK/log"; then bad "no placeholders left in the validated copy"; else pass "no placeholders left in the validated copy"; fi
expect_grep "render keeps the placeholder for Flux" 'host: ${APP_HOST}' "$WORK/out/app.yaml"
if [ "$(cat "$WORK/list")" = $'app.yaml\npreview/app.yaml' ]; then pass "list file"; else bad "list file: $(cat "$WORK/list")"; fi

# 2. Placeholder tags stay when IMAGES is empty (PR diffs).
RENDERS="app.yaml=deploy" bash "$SCRIPTS/render-all.sh" . "$WORK/out" "$WORK/list" validate > "$WORK/log" 2>&1
expect_grep "placeholder tag without images" "image: ghcr.io/example/app/api:0.0.0-dev" "$WORK/out/app.yaml"

# 3. An undocumented ${VAR} without a default fails the contract check; defaults are fine.
sed -i 's/`APP_HOST`/`OTHER`/' deploy/README.md
if RENDERS="app.yaml=deploy" bash "$SCRIPTS/render-all.sh" . "$WORK/out" "$WORK/list" validate > "$WORK/log" 2>&1; then
  bad "contract check catches undocumented var"
else
  expect_grep "contract check catches undocumented var" 'APP_HOST' "$WORK/log"
fi
if grep -q 'APP_MODE' "$WORK/log"; then bad "defaulted var is not reported"; else pass "defaulted var is not reported"; fi

# 4. The contract README is found above a nested deploy dir (deploy/app + deploy/README.md).
sed -i 's/`OTHER`/`APP_HOST`/' deploy/README.md
mkdir -p deploy/app && cp deploy/kustomization.yaml deploy/workload.yaml deploy/app/
if RENDERS="app/manifests.yaml=deploy/app" bash "$SCRIPTS/render-all.sh" . "$WORK/out" "$WORK/list" validate > "$WORK/log" 2>&1; then
  pass "README found one level up"
else
  bad "README found one level up"; cat "$WORK/log"
fi

# 5. Bad entries are rejected.
for entry in "deploy" "../x.yaml=deploy" "/abs.yaml=deploy" "x.yaml=missing-dir"; do
  if RENDERS="$entry" bash "$SCRIPTS/render-all.sh" . "$WORK/out" "$WORK/list" validate > "$WORK/log" 2>&1; then
    bad "rejects '$entry'"
  else
    pass "rejects '$entry'"
  fi
done
if IMAGES="ghcr.io/example/app/api:1.2.3" RENDERS="app.yaml=deploy" bash "$SCRIPTS/render-all.sh" . "$WORK/out" "$WORK/list" validate > "$WORK/log" 2>&1; then
  bad "rejects an image without a digest"
else
  pass "rejects an image without a digest"
fi

# 6. best-effort treats a missing or broken base as empty instead of failing.
mkdir -p "$WORK/emptybase"
if RENDERS="app.yaml=deploy" bash "$SCRIPTS/render-all.sh" "$WORK/emptybase" "$WORK/base" "$WORK/baselist" best-effort > "$WORK/log" 2>&1 && [ ! -e "$WORK/base/app.yaml" ]; then
  pass "best-effort with no base tree"
else
  bad "best-effort with no base tree"; cat "$WORK/log"
fi

# 7. Report: two named renders, one changed resource each, the Secret as an external node.
RENDERS=$'app.yaml=deploy\npreview/app.yaml=deploy,components/preview' \
  bash "$SCRIPTS/render-all.sh" . "$WORK/head" "$WORK/list" validate > /dev/null 2>&1
sed 's/path: \/api/path: \/v1/' "$WORK/head/app.yaml" > "$WORK/base-app.yaml"
sed 's/path: \/api/path: \/v1/' "$WORK/head/preview/app.yaml" > "$WORK/base-preview.yaml"
for f in "$WORK/head/app.yaml" "$WORK/head/preview/app.yaml" "$WORK/base-app.yaml" "$WORK/base-preview.yaml"; do
  yq -o=json -I=0 '.' "$f" > "$f.jsonl"
done
python3 "$SCRIPTS/manifest-report.py" --run-url https://example/run --marker test-key \
  app.yaml "$WORK/base-app.yaml.jsonl" "$WORK/head/app.yaml.jsonl" \
  preview/app.yaml "$WORK/base-preview.yaml.jsonl" "$WORK/head/preview/app.yaml.jsonl" > "$WORK/report.md"
expect_grep "report marker" "^<!-- test-key -->" "$WORK/report.md"
expect_grep "named sections" '#### `preview/app.yaml`' "$WORK/report.md"
expect_grep "change summary" "1 changed, 2 unchanged." "$WORK/report.md"
expect_grep "external Secret node" 'Secret/app-secrets' "$WORK/report.md"
expect_grep "dyff detail" "@@ stub dyff @@" "$WORK/report.md"
if [ "$(grep -c 'Secret/app-secrets' "$WORK/report.md")" = 1 ]; then pass "preview map has no Secret"; else bad "preview map has no Secret"; fi

# 8. A single render gets no section heading.
python3 "$SCRIPTS/manifest-report.py" app.yaml "$WORK/head/app.yaml.jsonl" "$WORK/head/app.yaml.jsonl" > "$WORK/report1.md"
if grep -q '^####' "$WORK/report1.md"; then bad "single render has no heading"; else pass "single render has no heading"; fi
expect_grep "no-change summary" "No change (3 unchanged)." "$WORK/report1.md"

# 9. A Helm chart render: values files in order, release name from the chart dir.
mkdir -p chart/templates
cat > chart/Chart.yaml <<'EOF'
apiVersion: v2
name: web
version: 1.0.0
EOF
cat > chart/values.yaml <<'EOF'
image: ghcr.io/example/web:1.0.0
replicas: 1
EOF
printf 'replicas: 2\n' > chart/values-prod.yaml
cat > chart/templates/all.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ .Release.Name }}
  labels:
    helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
---
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: {{ .Release.Name }}-kv
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: https://example.vault.azure.net
      serviceAccountRef:
        name: {{ .Release.Name }}
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: {{ .Release.Name }}-secrets
spec:
  secretStoreRef:
    kind: SecretStore
    name: {{ .Release.Name }}-kv
  target:
    name: {{ .Release.Name }}-secrets
  data:
  - secretKey: PASSWORD
    remoteRef:
      key: password
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ .Release.Name }}
  labels:
    helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
spec:
  replicas: {{ .Values.replicas }}
  selector:
    matchLabels:
      app: {{ .Release.Name }}
  template:
    metadata:
      labels:
        app: {{ .Release.Name }}
    spec:
      serviceAccountName: {{ .Release.Name }}
      containers:
      - name: web
        image: {{ .Values.image }}
        env:
        - name: PASSWORD
          valueFrom:
            secretKeyRef:
              name: {{ .Release.Name }}-secrets
              key: PASSWORD
EOF
if RENDERS="web.yaml=helm:chart,values-prod.yaml" bash "$SCRIPTS/render-all.sh" . "$WORK/helm" "$WORK/helmlist" validate > "$WORK/log" 2>&1; then
  pass "helm render"
else
  bad "helm render"; cat "$WORK/log"
fi
expect_grep "helm values file applied" "replicas: 2" "$WORK/helm/web.yaml"
expect_grep "helm release name from the chart dir" "name: chart-secrets" "$WORK/helm/web.yaml"
expect_grep "helm render validated" "validated: .*image: ghcr.io/example/web:1.0.0" "$WORK/log"
if RENDERS="web.yaml=helm:chart,missing.yaml" bash "$SCRIPTS/render-all.sh" . "$WORK/helm-x" "$WORK/helmlist-x" validate > "$WORK/log" 2>&1; then
  bad "helm render rejects a missing values file"
else
  pass "helm render rejects a missing values file"
fi
if RENDERS="web.yaml=helm:deploy" bash "$SCRIPTS/render-all.sh" . "$WORK/helm-x" "$WORK/helmlist-x" validate > "$WORK/log" 2>&1; then
  bad "helm render rejects a dir without Chart.yaml"
else
  pass "helm render rejects a dir without Chart.yaml"
fi

# 10. Report on the chart: a version bump alone (helm.sh/chart) is no change; ESO wiring is drawn.
sed -i 's/^version: 1.0.0/version: 1.1.0/' chart/Chart.yaml
RENDERS="web.yaml=helm:chart,values-prod.yaml" bash "$SCRIPTS/render-all.sh" . "$WORK/helm2" "$WORK/helmlist2" validate > /dev/null 2>&1
yq -o=json -I=0 '.' "$WORK/helm/web.yaml" > "$WORK/helm-base.jsonl"
yq -o=json -I=0 '.' "$WORK/helm2/web.yaml" > "$WORK/helm-head.jsonl"
python3 "$SCRIPTS/manifest-report.py" web.yaml "$WORK/helm-base.jsonl" "$WORK/helm-head.jsonl" > "$WORK/report-helm.md"
expect_grep "chart version bump alone is no change" "No change (4 unchanged)." "$WORK/report-helm.md"
expect_grep "ExternalSecret -> SecretStore" '|"store"|' "$WORK/report-helm.md"
expect_grep "SecretStore -> ServiceAccount" '|"logs in as"|' "$WORK/report-helm.md"
if grep -q '(\["Secret/chart-secrets"\])' "$WORK/report-helm.md"; then
  bad "the Secret an ExternalSecret creates is not external"
else
  pass "the Secret an ExternalSecret creates is not external"
fi

exit "$fail"
