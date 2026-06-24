# Consumer topologies

How thin-caller workflows in *consumer* repos wire up the reusable workflows and
composite actions in this repo. Every diagram below is drawn from a real consumer
so you can copy the shape that matches your repo.

These examples track the current major (`@v2`). The reference consumers shown here
(`clutterstock`, `wsh-rtl-sdr`, `proxmox`) currently pin a commit SHA of the previous
major and bump to `@v2` as part of their migration; the `test-*` repos are the
minimal canonical examples for each scenario.

## How to read these

A *thin caller* is a workflow in your repo that mostly just sets `uses:`, `with:`,
`needs:`, and an `if:` gate. The heavy lifting (build, scan, push, sign, attest,
publish) lives in this repo. There are two ways your repo touches this library, and
the distinction matters for OIDC identity:

- **Reusable workflow** (`uses:` at the **job** level, `.github/workflows/x.yml@v2`)
  — owns the job it defines. Its OIDC token carries **this repo's**
  `job_workflow_ref`, so anything it signs is signed under the shared
  `hwinther/reusable-workflows` identity.
- **Composite action** (`uses:` at the **step** level, `.github/actions/x@v2`) —
  runs **inline in your job**, so its OIDC token carries **your** repo's ref. This
  is why `sign-image` is a composite: it lets signatures bind to the consumer's
  identity. See **Consumer-side signing** below.

```mermaid
flowchart LR
  A["reusable workflow<br/>uses: .../workflows/x.yml@v2"]:::rw
  B["composite action<br/>uses: .../actions/x@v2"]:::ca
  C["consumer-owned job<br/>runs-on: ubuntu-latest"]:::cj
  D["external / cross-repo<br/>registry, other repo, upstream"]:::ext
  A ~~~ B ~~~ C ~~~ D
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

Solid arrows are `needs:` ordering (and what flows along them); dotted arrows are
data/artifacts that travel between jobs without being the primary dependency.

## The layering

Consumers almost never touch the internal (`_`-prefixed) building blocks directly —
they call a reusable workflow or a public composite, which fans out to the internals.

```mermaid
flowchart TD
  caller["your thin caller workflow"]:::cj
  subgraph lib["hwinther/reusable-workflows"]
    rw["reusable workflows<br/>docker-container.yml · build-and-scan-*.yml<br/>image-push.yml · pr-build.yml · package-deploy.yml"]:::rw
    pub["public composites<br/>node/dotnet/python-build · gitversion<br/>sign-image · verify-image"]:::ca
    int["internal composites (_-prefixed)<br/>_build-image-* · _scan-image · _push-image-with-signatures<br/>_compose-image-tags · _save/_load-image-artifact · _format-output"]:::int
  end
  caller --> rw
  caller -. consumer-side signing .-> pub
  rw --> pub
  rw --> int
  pub --> int
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef int fill:#fef9c3,stroke:#ca8a04,color:#713f12
```

---

# Minimal examples — `test-*`

Each `test-*` repo isolates one scenario. Start here; the advanced repos are just
several of these composed together.

## Single-image container publish — `test-ghcr/web-container.yml`

Push to `main` (or manual dispatch) → one reusable job builds, scans, pushes, signs,
and attests. This is the smallest useful shape. `api-container.yml` is identical but
calls `dotnet-container.yml` (build via `dotnet publish -t:PublishContainer`).

```mermaid
flowchart LR
  trig["push: main (images/web/**)<br/>or workflow_dispatch"]:::cj
  job["web_container<br/>docker-container.yml@v2<br/>container_image_name_postfix: web<br/>build_context/dockerfile: images/web<br/>grype_fail_build: auto"]:::rw
  ghcr["ghcr.io/&lt;owner&gt;/&lt;repo&gt;/web<br/>+ cosign sig + attestations"]:::ext
  trig --> job --> ghcr
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

## Multi-arch + per-arch scan — `test-ghcr/multiarch-container.yml`

Same single-job shape, but `platforms: linux/amd64,linux/arm64` triggers a buildx
manifest-list build, and `scan_all_platforms: true` runs Grype against each arch
separately (distinct SARIF category per arch in Code Scanning).

```mermaid
flowchart LR
  trig["push: main / dispatch"]:::cj
  job["multiarch_container<br/>docker-container.yml@v2<br/>platforms: amd64,arm64<br/>scan_all_platforms: true"]:::rw
  ghcr["ghcr.io/.../multiarch<br/>(manifest list: amd64 + arm64)"]:::ext
  trig --> job --> ghcr
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

## PR container e2e → label-gated push — `test-ghcr/pr-test.yml`

The PR flow never pushes until e2e passes **and** the PR carries `deploy-feature`.
Images move between jobs as a `docker save | gzip` artifact so the **byte-identical**
content is what gets tested and later pushed. `clutterstock/pr-e2e.yml` is this same
pattern scaled to three images plus a preview deploy.

```mermaid
flowchart TD
  subgraph bs["build + scan (parallel, no push)"]
    web["web<br/>build-and-scan-docker.yml@v2"]:::rw
    api["api<br/>build-and-scan-dotnet.yml@v2"]:::rw
    ma["multiarch<br/>build-and-scan-docker.yml@v2"]:::rw
  end
  pweb["push-web<br/>image-push.yml@v2"]:::rw
  papi["push-api<br/>image-push.yml@v2"]:::rw
  web -->|"image_artifact, tags,<br/>image_digest, sbom/grype"| pweb
  api -->|"image_artifact, tags,<br/>image_digest, sbom/grype"| papi
  note["if: PR + label 'deploy-feature'<br/>(image-push asserts loaded digest<br/>== build-time digest before pushing)"]:::cj
  note -.-> pweb
  note -.-> papi
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
```

> In `test-ghcr` the e2e step is omitted (no app to drive); `clutterstock` inserts a
> `playwright-e2e.yml` job between build and push — see below.

## Consumer-side signing — `test-ghcr/web-container-consumer-signs.yml`

The canonical per-consumer-identity flow: build/scan **without** signing, push with
all sign flags off, then sign **in your own job** so the Fulcio cert SAN is your repo,
and finally verify it round-trips. Four jobs, each cross-checked against the previous.

```mermaid
flowchart TD
  build["build<br/>build-and-scan-docker.yml@v2<br/>generate_supply_chain_artifacts: true"]:::rw
  push["push<br/>image-push.yml@v2<br/>cosign_sign_enabled: false<br/>cosign_supply_chain_attest_enabled: false<br/>attest_build_provenance_enabled: false"]:::rw
  sign["sign (your job)<br/>docker login → download sbom/grype →<br/>sign-image@v2 (composite)"]:::ca
  verify["verify (your job)<br/>verify-image@v2 (composite)"]:::ca
  ghcr["ghcr.io/.../web<br/>sig SAN = YOUR repo's workflow ref"]:::ext

  build -->|"image_artifact, image_digest (config-blob),<br/>sbom_artifact, grype_artifact,<br/>sbom_cyclonedx_sha256, grype_json_sha256"| push
  build -.->|"sbom/grype artifacts + sha256s + expected_image_id"| sign
  push -->|"pushed_digest (registry manifest)"| sign
  sign --> ghcr
  push --> verify
  sign --> verify
  verify -.->|"cosign verify + verify-attestation<br/>cert-identity = github.workflow_ref"| ghcr
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

Integrity is pinned at every hop: the push job asserts the loaded image-ID matches
build, the sign job re-hashes the predicate files against `*_sha256` and checks the
CycloneDX `syft:image` binding against `expected_image_id`, cosign binds to the
registry `pushed_digest`, and verify confirms the signature exists under your identity.

> **v2 slimming:** `sign-image@v2` can download the predicates itself
> (`sbom_artifact_name` / `grype_artifact_name`) and auto-resolve the digest from the
> first `container_tags` entry — so the explicit `download-artifact` + path-resolve
> steps in the `sign` job become optional. The verbose form above still works and
> keeps the cross-job sha256 checks.

## PR build (lint / test) — `test-{npm,nuget,pypi}/*-pr.yml`

One reusable job per package, gated to the files that changed. `pr-build.yml`
auto-detects stacks; pass `node_enabled` / `dotnet_enabled` / `python_enabled`.

```mermaid
flowchart LR
  pr["pull_request"]:::cj
  prb["pr-build.yml@v2<br/>detect-changes → node/dotnet/python-build<br/>(one combined PR comment)"]:::rw
  pr --> prb
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
```

`clutterstock/ci.yml` is the multi-stack version of this (Node frontend +
`openapi-typescript` extra command, plus .NET backend, in one call).

## Package publish + fanout — `test-{npm,nuget}/*-publish.yml`

Consumers call the layer-2 `package-deploy.yml`, which computes one shared version and
fans out to the per-ecosystem deploy workflows. They do **not** call `npm-deploy.yml`
/ `nuget-deploy.yml` directly. `is_alpha` keys off PR vs `main`.

```mermaid
flowchart TD
  trig["dispatch / push: main /<br/>PR + label 'publish-alpha'"]:::cj
  pd["deploy<br/>package-deploy.yml@v2<br/>is_alpha: PR?<br/>npm_enabled / nuget_enabled"]:::rw
  subgraph inside["inside package-deploy"]
    pv["package-version (composite)<br/>one shared semver"]:::ca
    npm["npm-deploy.yml@v2"]:::rw
    nug["nuget-deploy.yml@v2"]:::rw
  end
  reg["GitHub Packages<br/>(--tag alpha when is_alpha)"]:::ext
  trig --> pd --> pv
  pv --> npm
  pv --> nug
  npm --> reg
  nug --> reg
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

## PyPI trusted-publisher split — `test-pypi/*-publish.yml`

PyPI's OIDC trusted-publishing binds to the **calling** workflow's
`job_workflow_ref`, so the reusable side only **builds** the dist; the consumer runs
`pypa/gh-action-pypi-publish` in its **own** job (mirrors why `sign-image` is a
composite). The sdist+wheel flows across as a workflow artifact.

```mermaid
flowchart TD
  gate["gate (echo)"]:::cj
  build["build<br/>package-deploy.yml@v2<br/>pypi_enabled: true"]:::rw
  pub["publish (your job)<br/>environment: testpypi · id-token: write<br/>download-artifact → pypa/gh-action-pypi-publish"]:::cj
  pypi["test.pypi.org<br/>(trusted publisher = THIS workflow)"]:::ext
  gate --> build
  build -->|"pypi_built, pypi_artifact_name,<br/>pypi_version (sdist+wheel artifact)"| pub
  pub -->|"if: pypi_built == 'true'"| pypi
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

## Maintenance: registry pruning — `test-consumer/prune-*.yml`

Scheduled cleanup, thin wrappers around `prune-ghcr.yml` / `prune-npm.yml` /
`prune-nuget.yml`. Manual runs default to `dry_run: true`; the schedule forces a live
delete. Stable tags/versions and anything with a dist-tag are kept (fail-safe).

```mermaid
flowchart LR
  cron["schedule (Sun) / dispatch"]:::cj
  prune["prune<br/>prune-ghcr|npm|nuget.yml@v2<br/>dry_run: schedule ? false : input"]:::rw
  cron --> prune
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
```

---

# Advanced — `clutterstock` (full-stack app)

A .NET API + migrator + React frontend. It composes nearly every reusable workflow:
PR build, PR container e2e with label-gated push, GitOps preview deploy, release
fan-out, and maintenance. Three deployable images (`api`, `migrator`, `frontend`)
flow through each pipeline in parallel.

## `pr-e2e.yml` — the centerpiece

Build+scan all three images (no push) → Playwright e2e against the loaded images →
**label-gated** push of the byte-identical images → render a GitOps preview overlay
into the `hwinther/proxmox` repo → comment the preview URL. Everything after e2e is
gated on the `deploy-feature` label.

```mermaid
flowchart TD
  subgraph bs["build + scan (parallel, no push)"]
    api["api<br/>build-and-scan-dotnet.yml@v2"]:::rw
    mig["migrator<br/>build-and-scan-dotnet.yml@v2"]:::rw
    fe["frontend<br/>build-and-scan-docker.yml@v2"]:::rw
  end
  e2e["e2e — playwright-e2e.yml@v2<br/>image_artifacts_json = {API,MIGRATOR,FRONTEND}<br/>secrets: e2e_username/password/otp"]:::rw
  subgraph push["label-gated push (if: PR + 'deploy-feature')"]
    pa["push-api<br/>image-push.yml@v2"]:::rw
    pm["push-migrator<br/>image-push.yml@v2"]:::rw
    pf["push-frontend<br/>image-push.yml@v2"]:::rw
  end
  dp["deploy-preview<br/>gitops-preview-upsert.yml@v2<br/>target_repo: hwinther/proxmox"]:::rw
  cm["comment-preview-url<br/>(sticky PR comment)"]:::cj
  prox["hwinther/proxmox<br/>clusters/.../previews/clutterstock<br/>(Flux reconciles ~1 min)"]:::ext

  api -.->|"image_artifact"| e2e
  mig -.->|"image_artifact"| e2e
  fe -.->|"image_artifact"| e2e
  api --> pa
  mig --> pm
  fe --> pf
  e2e --> pa
  e2e --> pm
  e2e --> pf
  pa -->|"pushed_digest"| dp
  pm -->|"pushed_digest"| dp
  pf -->|"pushed_digest"| dp
  bs -.->|"version (per image)"| dp
  dp --> cm
  dp -->|"commit overlay (GitHub App token)"| prox
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

`pr-preview-cleanup.yml` is the mirror: on PR `closed`, a `teardown` job calls
`gitops-preview-teardown.yml` (removing the overlay so Flux prunes the namespace and
per-PR database), then a consumer job updates the sticky comment.

## `ci.yml` and the rest of the surface

```mermaid
flowchart LR
  ci["ci.yml (PR)"]:::cj --> prb["pr-build.yml@v2<br/>node (frontend + openapi-typescript)<br/>+ dotnet (backend)"]:::rw
  dl["dependabot-update-dotnet-lockfiles.yml"]:::cj --> dlr["dependabot-update-dotnet-lockfiles.yml@v2<br/>(WORKFLOW_TOKEN)"]:::rw
  rs["resharper-cleanupcode.yml"]:::cj --> rsr["format-and-create-pr.yml@v2<br/>(cleanupcode / blame-ignore-revs)"]:::rw
  st["stryker.yml"]:::cj --> str["stryker.yml@v2 (node)"]:::rw
  pg["prune-ghcr.yml"]:::cj --> pgr["prune-ghcr.yml@v2"]:::rw
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
```

## `tag-and-release.yml` — release fan-out

Tagging with `GITHUB_TOKEN` does **not** fire other workflows' `on: push: tags`
triggers, so the release does it manually: tag via the reusable workflow, then a
consumer job resolves the new tag and `gh workflow run`s each container build at that
ref. (This same workaround appears in `wsh-rtl-sdr` and `proxmox`.)

```mermaid
flowchart TD
  disp["workflow_dispatch (tag_name: auto)"]:::cj
  tag["tag<br/>tag-and-release.yml@v2<br/>(creates vX.Y.Z + floating tags)"]:::rw
  trig["trigger-container-builds (your job)<br/>resolve latest v* → gh workflow run"]:::cj
  apic["api-container.yml<br/>→ dotnet-container.yml@v2"]:::rw
  migc["migrator-container.yml<br/>→ dotnet-container.yml@v2"]:::rw
  fec["frontend-container.yml<br/>→ docker-container.yml@v2"]:::rw
  disp --> tag --> trig
  trig -->|"--ref vX.Y.Z"| apic
  trig -->|"--ref vX.Y.Z"| migc
  trig -->|"--ref vX.Y.Z"| fec
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
```

---

# Edge case — `wsh-rtl-sdr` (arm64 base image + SDR feeders)

Builds its **own** base image and a build-toolchain image, then a fleet of feeder
images derived from them — all `linux/amd64,linux/arm64`. Two things make it the
stress test for this library: **base-image chaining across a distro matrix**, and
**consumer-side signing per matrix leg**.

## `build-sdr-images.yml` — matrix chaining + consumer matrix signing

`precheck` skips the rebuild unless the upstream Debian digest moved. `sdr-build`
`needs: sdr-base` so the base is published before the toolchain `FROM`s it. Because
matrix-job outputs are last-writer-wins, the chain is wired through the
`sdr-base:<distro>` **floating tag** (passed via `build_args`), not a job output.
Signing is decoupled (`cosign_sign_enabled: false`) and done in per-distro consumer
jobs so the cert binds to `wsh-rtl-sdr`'s identity.

```mermaid
flowchart TD
  pc["precheck (your job)<br/>compare upstream debian:&lt;distro&gt;-slim digest"]:::cj
  ver["version<br/>gitversion.yml@v2"]:::rw
  sb["sdr-base  (matrix: buster/bullseye/bookworm/trixie)<br/>docker-container.yml@v2<br/>platforms: amd64,arm64 · cosign_sign_enabled: false<br/>tag_suffix/additional_tags/artifact_name_suffix = distro"]:::rw
  sbd["sdr-build  (matrix: 4 distros)<br/>docker-container.yml@v2<br/>build_args: SDR_BASE=ghcr.io/.../sdr-base:&lt;distro&gt;"]:::rw
  sbs["sdr-base-sign (matrix)<br/>sign-image@v2 (composite)"]:::ca
  sbds["sdr-build-sign (matrix)<br/>sign-image@v2 (composite)"]:::ca

  pc -->|"changed == true"| ver
  ver --> sb
  ver --> sbd
  sb -->|"FROM sdr-base:&lt;distro&gt; (floating tag)"| sbd
  sb -.->|"sbom/grype artifacts (per distro)"| sbs
  sbd -.->|"sbom/grype artifacts (per distro)"| sbds
  sb --> sbs
  sbd --> sbds
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
```

> Today each sign job installs crane, runs `crane digest`, and downloads the two
> predicate artifacts before calling `sign-image`. With `sign-image@v2` those steps
> collapse into the composite (`sbom_artifact_name`/`grype_artifact_name` + auto
> digest) — the ~100-line sign jobs become ~15 lines each.

## Feeder builds + Dockerfile digest-pinned `FROM`

Each feeder is a single `docker-container.yml` job with **reusable-side** signing.
Unlike `clutterstock`, the base→derived link is **not** a workflow output — the
feeder Dockerfile pins `FROM ghcr.io/.../sdr-base:<distro>@sha256:…` and Dependabot
bumps the digest. (Contrast with the workflow-output `image_digest` chaining shown in
the README's base-image-chaining example, which is what you'd use when base and
derived build in the **same** workflow run.)

```mermaid
flowchart LR
  base["ghcr.io/.../sdr-base:trixie@sha256:…<br/>ghcr.io/.../sdr-build:trixie@sha256:…"]:::ext
  feeder["build-&lt;feeder&gt;.yml  (×8: adsbexchange, piaware,<br/>dump1090-fa, tar1090, fr24, opensky, ais-catcher, gsm-tools)<br/>docker-container.yml@v2 · amd64,arm64 · reusable-side signing"]:::rw
  ghcr["ghcr.io/.../&lt;feeder&gt;"]:::ext
  base -->|"FROM (digest pin; Dependabot bumps)"| feeder --> ghcr
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

`tag-and-release.yml` dispatches the 8 feeder builds (not the base images, which
rebuild on their own path/cron cadence) — same tag→`gh workflow run` fan-out as
`clutterstock`.

---

# Edge case — `proxmox` (infrastructure / GitOps repo)

Not an app: a homelab IaC + GitOps repo (Kubernetes/Flux manifests for two clusters,
a Python provisioning library, and a couple of utility container images). It consumes
the library for the parts that *are* normal CI, and hand-rolls the
infrastructure-specific validation. It is also the **target** of `clutterstock`'s
preview deploys.

```mermaid
flowchart TD
  subgraph reused["consumes hwinther/reusable-workflows@v2"]
    prb["pr-build.yml (PR)<br/>→ pr-build.yml@v2 (python only, regex-gated)"]:::rw
    esp["build-esp-poller.yml<br/>setup (short_sha) → docker-container.yml@v2"]:::rw
    pbs["build-proxmox-pbs-backup-client.yml<br/>setup → docker-container.yml@v2"]:::rw
    fmt["format-and-create-pr.yml<br/>→ format-and-create-pr.yml@v2 (ruff-format)"]:::rw
    tag["tag-and-release.yml<br/>→ tag-and-release.yml@v2 → dispatch pbs build"]:::rw
    prune["prune-ghcr.yml@v2"]:::rw
  end
  subgraph handrolled["hand-rolled (no reuse)"]
    val["verify-k8s-job-name-bump · bump-k8s-job-name-on-label<br/>verify-dependabot-clusters (custom Python validators)<br/>update-flux (nightly Flux CLI PRs) · label · stale · poutine · zizmor"]:::cj
  end
  cluster["Flux on k0s clusters<br/>(production + edge-sdr / arm)"]:::ext
  fromcs["clutterstock deploy-preview<br/>commits preview overlays here"]:::ext

  tag -->|"--ref vX.Y.Z"| pbs
  esp --> cluster
  pbs --> cluster
  fromcs -.->|"GitOps overlay"| cluster
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

What makes it different from `clutterstock`:

- **PR build is Python-only**, gated by `python_changes_regex` to `src/`, `scripts/`,
  `pyproject.toml` — most PRs change YAML manifests, not Python.
- **Image tags carry a short SHA suffix** (`tag_suffix: <short_sha>`) so utility
  images don't collide on semver.
- **No deploy job** — "deploy" is a Flux reconcile of committed manifests, so the
  heavy machinery is the hand-rolled validators (Job-name bump enforcement, Dependabot
  cluster-dir sync, nightly Flux updates), none of which this library provides.

---

# Cross-cutting patterns

- **Release fan-out workaround.** A tag pushed by `GITHUB_TOKEN` won't trigger
  `on: push: tags` workflows. All three advanced consumers tag via
  `tag-and-release.yml`, then a consumer job resolves the tag and `gh workflow run`s
  the container builds at that ref.
- **Consumer-side signing for per-tenant identity.** Build with
  `cosign_sign_enabled: false` + `attest_build_provenance_enabled: false` (keep
  `cosign_supply_chain_attest_enabled: true` to still emit predicates), then call the
  `sign-image` **composite** in your own job. Because composites run inline, the
  Fulcio cert SAN is your repo — what per-consumer Kyverno/cosign policies need.
- **Two kinds of base-image chaining.** Same-run base→derived uses the base job's
  `image_digest` **output** as a `build_args` value (README base-image example).
  Cross-run / cross-matrix chaining (wsh-rtl-sdr) pins `FROM …@sha256:…` in the
  derived Dockerfile and lets Dependabot bump it.
- **Package fan-out + trusted publishing.** Consumers call `package-deploy.yml` (one
  shared version → per-ecosystem deploy). PyPI is special: the reusable side only
  builds the dist; the consumer runs `pypa/gh-action-pypi-publish` in its own job so
  the OIDC trusted-publisher binding stays pinned to the caller.
