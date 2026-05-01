# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A library of **reusable GitHub Actions workflows and composite actions** consumed by other repos as `hwinther/reusable-workflows/.github/workflows/<file>.yml@vMAJOR` or `.../.github/actions/<name>@vMAJOR`. Covers Node, .NET, Docker, GitVersion, npm publish, tag/release, and security scanning (poutine, zizmor). There is no application code to run locally — the "product" is the YAML.

## Versioning model (read this before touching anything)

The whole repo ships under one semver line. The current major lives in `.version-major` (currently `1`). Internal `uses:` references inside this repo must all point at that same major (`@v1`), and floating refs (`@main`, `@HEAD`) are forbidden. This is enforced by `scripts/validate-version-refs.mjs`, run by `.github/workflows/validate-version.yml` on every PR.

- **Non-breaking change**: edit, merge, optionally run the `Opprett tag og release` workflow. The `v1` floating tag gets moved to the new commit.
- **Breaking change**: bump `.version-major` (e.g. `1` → `2`), update internal `uses: …@v1` → `…@v2` everywhere in `.github/`, then release `v2.0.0` and create the `v2` floating tag.

`tag-and-release.yml` in `auto` mode bumps **minor** from the latest `vX.Y.Z` tag (resets patch to `0`) and force-pushes the floating `vX.Y` and `vX` tags.

## Local commands

```bash
# Validate that every internal `uses: hwinther/reusable-workflows/...@vN` matches .version-major
node ./scripts/validate-version-refs.mjs
```

There is no build/test/lint suite for the repo itself — all "testing" happens by the workflows being exercised in consumer repos. Prettier config (`.prettierrc`) is set up for JSON only.

## Repository layout

- `.github/actions/` — composite actions (the building blocks):
  - `node-build/` — npm install, `typecheck`, `build`, `lint:ci` (eslint --format json), `coverage:ci`. Parses output into GitHub annotations and a single combined PR-comment markdown blob exposed as the `pr-comment` output.
  - `dotnet-build/` — `dotnet restore --locked-mode`, `dotnet build -c Release`, `dotnet test` with Microsoft.Testing.Platform + coverlet + xunit trx, ReportGenerator coverage. Same PR-comment pattern.
  - `gitversion/` — runs GitVersion and emits `version`, `is_alpha`, container `deploy_tag` / `container_image_tags` / `image_tags`. Behaviour branches on whether `github.ref_name` is `main`, a `v*` tag, or anything else (alpha/prerelease).
- `.github/workflows/` — reusable workflows (`on: workflow_call`) that compose the actions:
  - `pr-build.yml` — one entry-point for PR builds. Runs a `detect-changes` job comparing against the PR base (or `origin/main` on push), then conditionally runs `node-build` and/or `dotnet-build` plus optional ReSharper InspectCode and TODO commenter.
  - `docker-container.yml` / `dotnet-container.yml` — gitversion → build → SBOM (Anchore) → Grype scan → push to GHCR → Cosign keyless sign → Cosign CycloneDX + vuln attestations → GitHub build provenance attestation.
  - `npm-deploy.yml` — publishes to GitHub Packages; uses `--tag alpha` when `is_alpha=true`.
  - `gitversion.yml` — thin reusable wrapper around the `gitversion` composite action.
  - `tag-and-release.yml` — manual or workflow_call; creates `vX.Y.Z` tag (+ floating `vX.Y` and `vX` when `floating_tags=true`) and a GitHub Release. Refuses to tag if HEAD already points at the latest semver tag.
  - `validate-version.yml` — runs the version-refs validator on PRs.
  - `poutine.yml`, `zizmor.yml` — Actions-targeted SAST that uploads SARIF to Code Scanning.

## Conventions to follow when editing workflows/actions

- **Pin every third-party action to a commit SHA with a `# vX.Y.Z` comment.** Dependabot (`.github/dependabot.yml`) is configured to update both `/` and `/.github/actions/*` weekly; keep the comment format intact so it can update cleanly.
- **Internal `uses:` refs use the major floating tag**, e.g. `uses: hwinther/reusable-workflows/.github/actions/node-build@v1`. The validator will fail PRs that use `@main`, `@HEAD`, or a different major.
- **`persist-credentials: false` on every `actions/checkout`** unless a later step in the same job needs to `git push` (then set it explicitly, as `gitversion/action.yml` does via the `persist_checkout_credentials` input). This is required for zizmor to pass.
- **Bash steps must `set +e` around the tool invocation, capture exit code, then act on it.** The node-build/dotnet-build actions deliberately don't fail fast — they collect typecheck/build/lint/test output into per-step markdown files in `$TEMP_DIR`, emit `::error file=…,line=…::` annotations, and combine everything into one `pr-comment` output before failing the step. Preserve this pattern when adding new checks.
- **Don't pass user-controlled values directly into shell `run:` blocks** without the `# zizmor: ignore[template-injection]` justification or routing through `env:`. See `docker-container.yml` for the established pattern of using `env:` for repo-controlled inputs and the `# zizmor: ignore` comment only for `inputs.*` that are paths/names.
- Many workflow names and descriptions are in **Norwegian** (e.g. `Opprett tag og release`, `Avgjør pakkeversjon`). Keep new strings in the same language as the file you're editing.
- Cosign is intentionally pinned to `v2.4.3` in the container workflows. Do not bump to v3 — the comment in `docker-container.yml` explains that Kyverno 1.17 `verifyImages` resolves attestations via the legacy `sha256-….att` manifest path that v3 publishes only as OCI referrers.

## GitVersion behavior

`GitVersion.yml` uses the `GitHubFlow/v1` workflow (mainline = `main`). The `gitversion` composite action's branching logic:

- On `main` → `version = MajorMinorPatch`, `is_alpha = false`, container tags `latest` + `MajorMinorPatch`.
- On a `v*` tag → same as main but no `latest` tag.
- Anywhere else (feature/PR branches) → `version = SemVer` (with prerelease suffix), `is_alpha = true`, container tag is the prerelease semver.

`is_alpha` is a **string** (`'true'`/`'false'`) because reusable-workflow outputs round-trip as strings.
