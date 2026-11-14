# Consumer topologies

How thin-caller workflows in *consumer* repos wire up the reusable workflows and
composite actions in this repo. Every diagram below is drawn from a real consumer
so you can copy the shape that matches your repo.

The `test-*` repos (under `wshno/`) are the minimal examples, one scenario each. The
advanced consumers (`clutterstock`, `wsh-rtl-sdr`, `proxmox`) pin a v2 release by commit
SHA, as every caller should. For how an app's workflows link up across PR, main, the
nightly run and release, see [workflow-map.md](workflow-map.md).

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
    rw1["one job per image<br/>docker-container.yml · dotnet-container.yml<br/>build-and-scan-*.yml · image-push.yml"]:::rw
    rw2["split image pipeline<br/>gitversion.yml · build-image-docker/dotnet.yml<br/>scan-image.yml · playwright-e2e.yml · image-push.yml"]:::rw
    rw3["build, results, deploy, release<br/>pr-build.yml · package-deploy.yml · quality-artifact.yml<br/>e2e-coverage-summary.yml · gitops-preview-upsert/teardown.yml<br/>nightly-preview-e2e.yml · tag-and-release.yml"]:::rw
    pub["public composites<br/>node/dotnet/python/go-build · gitversion · manifests<br/>quality-artifact · sign-image · verify-image<br/>sticky-pr-comment · otel-slow-spans · changed-files"]:::ca
    int["internal composites (_-prefixed)<br/>_build-image-* · _scan-image · _grype-summary<br/>_push-image-with-signatures · _push-staging-image<br/>_choose/_resolve-image-handoff · _save/_load-image-artifact<br/>_compose-image-tags · _format-output · _sticky-pr-comment"]:::int
  end
  caller --> rw1
  caller --> rw2
  caller --> rw3
  caller -. "consumer-side signing,<br/>manifests, PR comments" .-> pub
  rw1 --> pub
  rw2 --> pub
  rw3 --> pub
  rw1 --> int
  rw2 --> int
  pub --> int
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef int fill:#fef9c3,stroke:#ca8a04,color:#713f12
```

The two image shapes: **one job per image** builds, scans and pushes in a single reusable
job (release builds, utility images). The **split pipeline** builds each image once and
hands it on by reference, so scan and e2e run in parallel on the same bytes before the
push (app PRs and main; see [workflow-map.md](workflow-map.md)).

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
content is what gets tested and later pushed. This is the one-job-per-image shape
(`build-and-scan-*`); the app repos have moved to the split pipeline, where each image is
built once and scan and e2e run in parallel on it.

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

> In `test-ghcr` the e2e step is omitted (no app to drive). The apps' `pr-e2e.yml`
> (`build-image-*` → `scan-image` ‖ `playwright-e2e` → `image-push`) is drawn in
> [workflow-map.md](workflow-map.md).

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
auto-detects stacks; pass `node_enabled` / `dotnet_enabled` / `python_enabled` / `go_enabled`.

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

A .NET API + migrator + React frontend, deployed by Flux from a signed manifests
artifact. The pull request and main pipeline (`pr-e2e.yml`), the nightly preview run and
the quality flow are drawn in [workflow-map.md](workflow-map.md). This section covers
the release and the rest of the repo's workflows. skylens, romslig, pbs-browser,
ddnsadmin and `test` follow the same shape with fewer images.

## Release — `tag-and-release.yml` → `container.yml` → `promote.yml`

`tag-and-release.yml` pushes the `v*` tag with the devops-bot GitHub App's token (job in
the `devops-bot` environment). Unlike a tag pushed with `GITHUB_TOKEN`, that push fires
`on: push: tags`, so `container.yml` starts by itself at the tag: it rebuilds the three
images, then renders `deploy/` with them pinned to tag@digest and pushes it as
`manifests:<version>`, signed with the `container.yml@refs/tags/v*` identity. The test
environment follows new releases through its OCIRepository's `ref.semver`. Production
moves only through `promote.yml`.

```mermaid
flowchart TD
  disp["workflow_dispatch (tag_name: auto)"]:::cj
  tag["tag<br/>tag-and-release.yml<br/>app_client_id: DEVOPS_BOT_CLIENT_ID<br/>environment: devops-bot"]:::rw
  subgraph cont["container.yml (on: push: tags v*)"]
    api["api · migrator<br/>dotnet-container.yml"]:::rw
    fe["frontend<br/>docker-container.yml"]:::rw
    man["manifests (your job)<br/>manifests action<br/>render · push · sign"]:::ca
  end
  ghcr[("ghcr.io/.../manifests:&lt;version&gt;<br/>sig: container.yml@refs/tags/v*")]:::ext
  test[("test env<br/>OCIRepository ref.semver")]:::ext
  prom["promote.yml (dispatch from main)<br/>check signature · production approval<br/>co-sign · tag-bump PR in hwinther/proxmox"]:::cj
  prod[("production<br/>accepts only promote.yml's signature")]:::ext

  disp --> tag -->|"tag push (App token)"| cont
  api -->|"tag@digest"| man
  fe -->|"tag@digest"| man
  man --> ghcr
  ghcr -.-> test
  ghcr -.->|"version"| prom
  prom -->|"PR merged"| prod
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

If the Grype gate stops a release on findings that can't be fixed yet, run
`container.yml` by hand at the tag with "Fail the build" off.

## The rest of the surface

```mermaid
flowchart LR
  ci["ci.yml (PR)"]:::cj --> prb["pr-build.yml<br/>node (frontend + openapi-typescript)<br/>+ dotnet (backend)"]:::rw
  md["manifest-diff.yml (PR)"]:::cj --> mda["manifests action<br/>render head + base, diff comment"]:::ca
  cl["pr-preview-cleanup.yml (PR closed)"]:::cj --> clr["gitops-preview-teardown.yml"]:::rw
  np["nightly-preview.yml (cron)"]:::cj --> npr["nightly-preview-e2e.yml"]:::rw
  dl["dependabot-update-dotnet-lockfiles.yml"]:::cj --> dlr["dependabot-update-dotnet-lockfiles.yml<br/>(WORKFLOW_TOKEN)"]:::rw
  rs["resharper-cleanupcode.yml"]:::cj --> rsr["format-and-create-pr.yml<br/>(cleanupcode / blame-ignore-revs)"]:::rw
  st["stryker.yml"]:::cj --> str["stryker.yml (node)"]:::rw
  pg["prune-ghcr.yml"]:::cj --> pgr["prune-ghcr.yml"]:::rw
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
```

Repo-local, no reuse yet: `zap-scan.yml` (ZAP API scan against a mock-OIDC stack),
`api-docs-pages.yml` (GitHub Pages: API docs plus test and coverage reports),
`load-test.yml`, `nightly-e2e.yml` (being replaced by the nightly preview run) and
`contracts-nuget-publish.yml`. `manifest-diff`, `tag-and-release`, `dependabot-auto-merge`,
`label`, `type-label`, `stale`, `poutine` and `zizmor` are synced from `wshno/devops`
(header `# Synced from wshno/devops …`), so change them there.

---

# Edge case — `wsh-rtl-sdr` (multi-arch SDR feeders)

A fleet of independent `linux/amd64,linux/arm64` images (readsb, piaware, tar1090,
ais-catcher, …), each a static binary on distroless, plus a signed manifests artifact for
the edge-sdr cluster. There is no shared base image any more, so each image builds on
its own.

```mermaid
flowchart TD
  pr["pull_request (images/**)"]:::cj
  smoke["smoke-test.yml (your job)<br/>matrix: one image each, amd64<br/>docker-compose.test.yml, no SDR hardware"]:::cj
  main["push: main (images/&lt;image&gt;/**)"]:::cj
  bi["build-&lt;image&gt;.yml<br/>docker-container.yml<br/>amd64,arm64 · reusable-side signing"]:::rw
  disp["tag-and-release.yml<br/>v* tag via devops-bot"]:::rw
  subgraph rel["release.yml (on: push: tags v*)"]
    guard["guard: refs/tags/v* only"]:::cj
    mx["build (matrix: 9 images)<br/>docker-container.yml<br/>release_asset_upload_enabled: false"]:::rw
    man["manifests (your job)<br/>manifests action, signed as<br/>release.yml@refs/tags/v*"]:::ca
  end
  ghcr[("ghcr.io/hwinther/wsh-rtl-sdr/&lt;image&gt;<br/>+ manifests:&lt;version&gt;")]:::ext
  edge[("edge-sdr cluster<br/>Flux OCIRepository")]:::ext

  pr --> smoke
  main --> bi --> ghcr
  disp -->|"tag push"| guard --> mx --> man --> ghcr
  ghcr -.-> edge
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

What makes it different from `clutterstock`:

- **Two publish paths.** A merge that touches `images/<image>/` publishes that one image
  (`build-<image>.yml`). A release rebuilds all of them in one matrix and ships the
  manifests that pin them.
- **PRs don't build through the library.** `smoke-test.yml` builds each image amd64-only
  and runs it in a no-hardware mode (readsb as a `--net-only` hub, ais-catcher reading
  `/dev/zero`). The multi-arch build and Grype scan happen on main.
- **Upstream bumps** come from `bump-sources.yml` and `bump-fr24feed.yml` (weekly PRs for
  pinned sources Dependabot can't track), which dispatch the smoke test for the image.

---

# Edge case — `proxmox` (infrastructure / GitOps repo)

Not an app: a homelab IaC + GitOps repo (Kubernetes/Flux manifests for two clusters,
a Python provisioning library, and two utility container images). It consumes the
library for the parts that *are* normal CI and hand-rolls the infrastructure-specific
validation. It is also the **target** of every app's preview deploys and production
promotions.

```mermaid
flowchart TD
  subgraph reused["consumes hwinther/reusable-workflows"]
    prb["pr-build.yml<br/>→ pr-build.yml (python only, regex-gated)<br/>+ quality-artifact.yml"]:::rw
    esp["build-esp-poller.yml<br/>PR: build-and-scan-docker.yml<br/>tag esp-poller-v*: docker-container.yml"]:::rw
    pbs["build-proxmox-pbs-backup-client.yml<br/>PR: build-and-scan-docker.yml<br/>tag pbs-backup-client-v*: docker-container.yml"]:::rw
    md["manifest-diff.yml<br/>→ manifests action (Flux paths + HelmRelease charts)"]:::ca
    fmt["format-and-create-pr.yml<br/>→ format-and-create-pr.yml (ruff-format)"]:::rw
    tag["tag-and-release.yml<br/>→ tag-and-release.yml (repo-wide v*, builds nothing)"]:::rw
    prune["prune-ghcr.yml"]:::rw
  end
  subgraph handrolled["hand-rolled (no reuse)"]
    val["verify-k8s-job-name-bump · bump-k8s-job-name-on-label<br/>verify-dependabot-clusters (custom Python validators)<br/>update-flux (nightly Flux CLI PRs) · bump-pbs-client (weekly pin PR)<br/>label · stale · poutine · zizmor"]:::cj
  end
  cluster["Flux on k0s clusters<br/>(production + edge-sdr / arm)"]:::ext
  apps["app repos: preview overlays,<br/>promote.yml tag-bump PRs"]:::ext

  esp -->|"release tag only"| cluster
  pbs -->|"release tag only"| cluster
  apps -.->|"GitOps commits / PRs"| cluster
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

What makes it different from `clutterstock`:

- **PR build is Python-only**, gated by `python_changes_regex` to `src/`, `scripts/`,
  `pyproject.toml`: most PRs change YAML manifests, not Python.
- **Each image releases on its own tag prefix** (`esp-poller-v*`, `pbs-backup-client-v*`;
  GitVersion reads only that prefix). PRs build and scan without pushing, and merges to
  main publish nothing, so GHCR holds only release versions and Dependabot moves the
  CronJobs to them.
- **No deploy job.** "Deploy" is a Flux reconcile of committed manifests, so the heavy
  machinery is the hand-rolled validators (Job-name bump enforcement, Dependabot
  cluster-dir sync, nightly Flux updates), none of which this library provides.

---

# Cross-cutting patterns

- **Tag pushes that start the release.** A tag pushed with `GITHUB_TOKEN` doesn't fire
  `on: push: tags`. `tag-and-release.yml` therefore pushes with a GitHub App token
  (`app_client_id` + `app_private_key`, the devops-bot App), and the tag workflow
  (`container.yml`, `release.yml`) starts by itself. A hand-pushed tag works the same.
- **Release identity in the signature.** The manifests artifact is signed in the
  consumer's own job, so the cosign identity is `<workflow>.yml@refs/tags/v*`, which
  the cluster's OCIRepository verify pins. `promote.yml` adds a second signature that
  production requires.
- **Consumer-side signing for per-tenant identity.** Build with
  `cosign_sign_enabled: false` + `attest_build_provenance_enabled: false` (keep
  `cosign_supply_chain_attest_enabled: true` to still emit predicates), then call the
  `sign-image` **composite** in your own job. Because composites run inline, the
  Fulcio cert SAN is your repo — what per-consumer Kyverno/cosign policies need
  (`test-ghcr/web-container-consumer-signs.yml`).
- **Base-image chaining in one run.** A derived image built in the same run uses the
  base job's `image_digest` **output** as a `build_args` value (README base-image
  example). Across runs, pin `FROM …@sha256:…` in the derived Dockerfile and let
  Dependabot bump it.
- **Package fan-out + trusted publishing.** Consumers call `package-deploy.yml` (one
  shared version → per-ecosystem deploy). PyPI is special: the reusable side only
  builds the dist; the consumer runs `pypa/gh-action-pypi-publish` in its own job so
  the OIDC trusted-publisher binding stays pinned to the caller.
