# reusable-workflows

Reusable workflows, build and deploy for Node, .NET, Python, and Docker — plus composable building blocks for container supply-chain (SBOM, Grype, Cosign, build provenance), GitVersion, and security scanning.

## Available reusable workflows

Reference as `uses: hwinther/reusable-workflows/.github/workflows/<file>@v1`.

### Build & PR checks
- **`pr-build.yml`** — single PR-build entry point. Detects which stacks changed against the PR base and conditionally runs `node-build` and/or `dotnet-build`, plus optional ReSharper InspectCode and TODO commenter. Posts one combined PR comment.
- **`playwright-e2e.yml`** — downloads images produced by `build-and-scan-*.yml`, runs Playwright via `docker compose up --wait`, posts a sticky PR summary, uploads the HTML report + traces + compose logs.

### Container build, scan, push
- **`docker-container.yml`** — gitversion → `docker buildx` → SBOM (Anchore) → Grype scan → push to GHCR → Cosign keyless sign → Cosign CycloneDX + vuln attestations → GitHub build provenance attestation. Single-job, push-always. Supports multi-arch (`platforms`), per-arch scanning, and `build_args` for base-image chaining.
- **`dotnet-container.yml`** — same pipeline as above using `dotnet publish -t:PublishContainer` for the build.
- **`build-and-scan-docker.yml`** / **`build-and-scan-dotnet.yml`** — same build + SBOM + Grype gate **without** push. Uploads the loaded image as a workflow artifact for byte-identical hand-off to e2e and an optional later push.
- **`image-push.yml`** — downloads the image artifact from `build-and-scan-*.yml`, asserts byte-identity against the build-time digest, then `_push-image-with-signatures` (sign + attest + provenance). Caller owns the `if:` gate (PR label, branch, …).
- **`prune-ghcr.yml`** — deletes orphaned GHCR manifests: untagged non-referrer manifests, prerelease tags for branches no longer on origin, and dangling cosign legacy `.sig`/`.att`/`.sbom` tags.

### Package publishing
- **`npm-deploy.yml`** — publishes to GitHub Packages (or any npm registry); uses `--tag alpha` when `is_alpha=true`.
- **`nuget-deploy.yml`** — packs every `IsPackable=true` project in a solution and pushes to a NuGet feed.
- **`pypi-deploy.yml`** — builds + checks a Python distribution and uploads it as a workflow artifact. Caller runs `pypa/gh-action-pypi-publish` themselves so PyPI's `job_workflow_ref` trusted-publisher binding stays narrow.
- **`package-deploy.yml`** — layer-2 fanout: computes one shared version, optionally change-detects per ecosystem, then calls the per-ecosystem layer-1 workflows (npm/nuget/pypi).

### Versioning & releases
- **`gitversion.yml`** — thin wrapper around the `gitversion` composite action.
- **`tag-and-release.yml`** — creates `vX.Y.Z` tag (+ floating `vX.Y` and `vX` when `floating_tags=true`) and a GitHub Release. In `auto` mode, bumps minor from the latest tag.
- **`validate-version.yml`** — runs `scripts/validate-version-refs.mjs` to enforce that internal `uses:` refs match `.version-major` and that no `@main`/`@HEAD` floats slip in.

### Maintenance & quality
- **`stryker.yml`** — Stryker mutation testing for .NET (off by default — current MTP/dotnet-stryker hangs) and/or Node (on by default). Each is gated by an input flag.
- **`resharper-cleanupcode.yml`** — runs `jb cleanupcode` against a .NET solution and opens a PR (`mode: cleanupcode`), or syncs `.git-blame-ignore-revs` from prior CleanupCode commits (`mode: blame-ignore-revs`).
- **`dependabot-update-dotnet-lockfiles.yml`** — for `pull_request_target`: on labelled dependabot PRs, refreshes `packages.lock.json` files and pushes back to the PR branch via a caller-supplied `WORKFLOW_TOKEN`.

### Security scanning
- **`poutine.yml`** — Actions-targeted SAST; uploads SARIF to Code Scanning.
- **`zizmor.yml`** — Actions-targeted SAST; uploads SARIF to Code Scanning.

## Available composite actions

Reference as `uses: hwinther/reusable-workflows/.github/actions/<name>@v1`.

- **`node-build`** — npm install + typecheck + build + `lint:ci` + `coverage:ci`. Every step runs even on prior failure; output is parsed into GitHub annotations and a combined PR-comment markdown blob (`pr-comment` output).
- **`dotnet-build`** — `dotnet restore --locked-mode` + build + test (Microsoft.Testing.Platform + coverlet + xunit trx) + ReportGenerator coverage. Same fail-late + `pr-comment` pattern as `node-build`.
- **`python-build`** — ruff + mypy + pytest + `python -m build`. Same fail-late + `pr-comment` pattern.
- **`gitversion`** — runs GitVersion and emits `version`, `is_alpha`, container `deploy_tag` / `container_image_tags` / `image_tags`. Branches on whether `github.ref_name` is `main`, a `v*` tag, or anything else (alpha).
- **`package-version`** — computes a version from the latest reachable `v[X.Y.Z]` tag + commit count, in either `semver` or `pep440` format. Used by `package-deploy.yml` to share one version across ecosystems.

Internal helpers (prefixed `_`) are implementation details of the workflows above and are not part of the public surface: `_build-image-docker`, `_build-image-dotnet`, `_scan-image`, `_grype-summary`, `_format-output`, `_push-image-with-signatures`, `_save-image-artifact`, `_load-image-artifact`, `_dotnet-add-nuget-source`.

## Typical usage patterns

### PR build (Node / .NET / Python)

```
consumer caller workflow  (on: pull_request)
        │
        └─ pr-build.yml
              ├─ detect-changes  (diff vs PR base)
              ├─ node-build      (composite — typecheck + build + lint + coverage)
              ├─ dotnet-build    (composite — restore + build + test + coverage)
              └─ posts ONE combined PR comment with all results
```

### Container PR flow — build → e2e → label-gated push

The image flows between jobs as a workflow artifact (`docker save | gzip`) so the byte-identical content is what gets e2e-tested and later pushed.

```
consumer caller workflow  (on: pull_request)
        │
        ├─ build-and-scan-{docker,dotnet}.yml ───────────┐
        │     ├─ gitversion                              │  outputs:
        │     ├─ _build-image-{docker,dotnet}            │    image_artifact
        │     ├─ _scan-image    (SBOM + Grype SARIF)     │    image_digest
        │     └─ _save-image-artifact                    │    container_image_tags
        │                                                │
        ├─ playwright-e2e.yml   (needs: build) ◀─────────┤
        │     ├─ _load-image-artifact (per image)        │
        │     ├─ docker compose up --wait                │
        │     └─ run Playwright + sticky PR comment      │
        │                                                │
        └─ image-push.yml       (needs: build, e2e;  ◀───┘
                                 if: label / branch)
              ├─ _load-image-artifact
              ├─ verify local digest == build-time digest
              └─ _push-image-with-signatures
                    ├─ docker push (per tag)
                    ├─ attest-build-provenance     ── SLSA v1.0 provenance
                    ├─ cosign sign (keyless OIDC)
                    └─ cosign attest CycloneDX + Grype vuln  (Kyverno-friendly)
```

### Container release — push to `main` or a `v*` tag

Single job, push-always. Same building blocks as the PR flow, no artifact hop.

```
consumer caller workflow  (on: push to main / v*)
        │
        └─ {docker,dotnet}-container.yml
              ├─ gitversion
              ├─ _build-image-{docker,dotnet}
              │     └─ multi-arch via buildx when platforms = "linux/amd64,linux/arm64"
              ├─ _scan-image    (per-arch SARIF when scan_all_platforms=true)
              └─ _push-image-with-signatures
                    ├─ docker push  /  buildx manifest-list push
                    ├─ attest-build-provenance
                    ├─ cosign sign
                    └─ cosign attest CycloneDX + vuln
```

### Package publishing fan-out

One shared version across ecosystems; each layer-1 workflow only runs when enabled and (optionally) when its files changed.

```
consumer caller workflow  (on: push to main, etc.)
        │
        └─ package-deploy.yml
              ├─ package-version  (composite — one shared semver/pep440 version)
              ├─ change-detect per ecosystem (optional)
              │
              ├─ npm-deploy.yml    (npm_enabled   & changed)
              ├─ nuget-deploy.yml  (nuget_enabled & changed)
              └─ pypi-deploy.yml   (pypi_enabled  & changed)
                    └─ uploads built sdist+wheel as workflow artifact
                          │
                          ▼
                    consumer's OWN publish job
                    runs pypa/gh-action-pypi-publish
                    (keeps OIDC job_workflow_ref pinned to caller —
                     trusted-publisher binding stays narrow)
```

### Base-image chaining (digest-pinned `FROM`)

`docker-container.yml` exposes the pushed image's digest as a job output; downstream image jobs `FROM` that exact digest via `build_args`, so a base-image rebuild can never silently change what a derived image points at.

```
sdr-base-runtime:   docker-container.yml
        │
        │  outputs.image_digest = sha256:abc…
        ▼
adsbexchange:       docker-container.yml   (needs: sdr-base-runtime)
   with:
     build_args: |
       SDR_BASE_RUNTIME=ghcr.io/<repo>/sdr/sdr-base-wsh@sha256:abc…

   Dockerfile:
     ARG SDR_BASE_RUNTIME
     FROM $SDR_BASE_RUNTIME AS runtime
```

## Versioning

This repository is versioned as a single unit using semantic versioning:

- **Major** version: breaking changes to any reusable workflow or composite action.
- **Minor/Patch** versions: backwards compatible changes (bug fixes, improvements, new non-breaking features).

The current major version for `main` is stored in the `.version-major` file at the repository root.

Consumers should reference workflows and actions from this repository using the **moving major tag** that matches the value in `.version-major`:

- Reusable workflow example:
  - `uses: hwinther/reusable-workflows/.github/workflows/pr-build.yml@v1`
- Composite action example:
  - `uses: hwinther/reusable-workflows/.github/actions/node-build@v1`

When a breaking change is introduced, the major in `.version-major` is incremented (for example from `1` to `2`) and a new `v2.0.0` tag is created along with a moving `v2` tag that points at the latest compatible commit.

### Release and tagging process

- **Non-breaking changes (same major)**:
  - Implement and merge the change to `main`.
  - Optionally run the `Opprett tag og release` workflow to create a new `vMAJOR.MINOR.PATCH` tag and GitHub Release.
  - Move the moving major tag (for example `v1`) to the latest stable commit.

- **Breaking changes (new major)**:
  - Update `.version-major` to the new major (for example from `1` to `2`).
  - Update any documentation examples that reference the old major tag if needed.
  - Merge the change to `main`.
  - Run the `Opprett tag og release` workflow to create an initial `vMAJOR.0.0` tag (for example `v2.0.0`).
  - Create or move the moving major tag (for example `v2`) to point at this release commit.

The `Validate version references` workflow runs on pull requests to `main` and ensures that any `uses: hwinther/reusable-workflows/.github/...@vX` references inside `.github/workflows` and `.github/actions` stay compatible with the declared major in `.version-major` and do not use floating refs like `@main` or `@HEAD`.
