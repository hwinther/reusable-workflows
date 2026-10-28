#!/usr/bin/env bash
# Tests for .github/actions/manifests/scripts (render-all.sh, render-manifests.sh,
# manifest-report.py).
#
# Builds a small fixture app (deploy/ with a Deployment, Service, Ingress, a README contract and
# a preview Component) in a work dir, then checks image pinning, components, the contract check,
# renders-entry validation, best-effort base rendering and the multi-render report. kubeconform
# and dyff are stubbed: this tests our scripts, not those tools. Needs kubectl (kustomize),
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

exit "$fail"
