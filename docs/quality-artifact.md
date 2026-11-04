# Quality artifact

Each app repo publishes its test, coverage and scan results as one signed OCI artifact per build:

```
ghcr.io/<owner>/<repo>/quality:<tag>     e.g. ghcr.io/hwinther/clutterstock/quality:main-abc1234
```

A central repo can then list every app's quality by reading one small file per repo, without
knowing how each repo builds or tests.

## Producing it

Jobs upload their reports as workflow artifacts named `quality-<component>`. The reusable pieces
already do this:

| Producer | Artifact | Contents |
|---|---|---|
| `node-build` (via `pr-build.yml`) | `quality-node` | JUnit XML, Vitest JSON, Cobertura XML / Istanbul `coverage-summary.json` from `coverage/`; `warnings.json` (typecheck, build, lint) |
| `python-build` (via `pr-build.yml`) | `quality-python` | pytest JUnit XML, Cobertura (`coverage.xml`), `warnings.json` (pytest warnings) |
| `dotnet-build` (via `pr-build.yml`) | `quality-dotnet` | TRX and Cobertura XML from `**/TestResults`; `warnings.json` (restore, build, test) |
| `playwright-e2e.yml` | `quality-e2e` | Playwright JSON report (`results_json_path`) |
| `scan-image.yml` and the other image scans | `quality-scan-<postfix>` | Grype JSON |

`quality-artifact.yml` runs last in the same workflow run. It downloads every `quality-*`
artifact, writes `summary.json`, pushes the artifact and signs it:

```yaml
quality:
  needs: [main-tag, version, unit, e2e, api-scan, frontend-scan]
  if: ${{ !cancelled() && github.event_name == 'push' }}
  permissions:
    contents: read
    packages: write
    id-token: write
  uses: hwinther/reusable-workflows/.github/workflows/quality-artifact.yml@<sha> # vX.Y.Z
  with:
    tags: |
      ${{ needs.main-tag.outputs.tag }}   # main-<sha7>
      main
    version: ${{ needs.version.outputs.version }}
```

`pr-build.yml` builds every enabled stack on `push` and `schedule`, so calling it on a push to main
gives unit results for the whole repo, not only for what changed.

Any other job can join by uploading a `quality-<name>` artifact in one of the formats below.

## Layout

| Layer | Media type | Contents |
|---|---|---|
| `summary.json` | `application/vnd.wsh.quality.summary.v1+json` | The summary below. The only layer a dashboard needs. |
| `reports.tar.gz` | `application/vnd.wsh.quality.reports.v1.tar+gzip` | The raw reports, one directory per `quality-*` artifact. |

The same `summary.json` is also uploaded as the workflow artifact `quality-summary` (90 days), for
readers that have Actions read access but no registry credentials, e.g. on a private repo.

The artifact type is `application/vnd.wsh.quality.v1`. Its manifest carries the
`org.opencontainers.image.{source,revision,version,created}` annotations, and it is signed with
cosign keyless.

Who signed it depends on where the signing ran:

- **Through `quality-artifact.yml`** (a reusable workflow), the certificate identity is that
  workflow at the caller's pinned commit,
  `https://github.com/hwinther/reusable-workflows/.github/workflows/quality-artifact.yml@<sha>`. The
  calling repo and ref are in the certificate's GitHub extensions:

  ```sh
  cosign verify ghcr.io/hwinther/clutterstock/quality:main \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github[.]com/hwinther/reusable-workflows/[.]github/workflows/quality-artifact[.]yml@' \
    --certificate-github-workflow-repository hwinther/ClutterStock \
    --certificate-github-workflow-ref refs/heads/main
  ```

- **Through the `quality-artifact` action** in the caller's own job, the identity is the caller's
  workflow, e.g. `https://github.com/hwinther/ClutterStock/.github/workflows/pr-e2e.yml@refs/heads/main`
  (same as `manifests` and `sign-image`).

Reading only the summary:

```sh
oras manifest fetch ghcr.io/hwinther/clutterstock/quality:main \
  | jq -r '.layers[] | select(.mediaType == "application/vnd.wsh.quality.summary.v1+json") | .digest' \
  | xargs -I{} oras blob fetch --output - ghcr.io/hwinther/clutterstock/quality@{}
```

## summary.json (schemaVersion 1)

```json
{
  "schemaVersion": 1,
  "repository": "hwinther/ClutterStock",
  "commit": "<full sha>",
  "ref": "refs/heads/main",
  "version": "0.31.1",
  "createdAt": "2026-11-04T18:00:00Z",
  "run": { "id": "123", "url": "https://github.com/hwinther/ClutterStock/actions/runs/123" },
  "components": {
    "dotnet": {
      "kind": "unit",
      "tests": { "total": 42, "passed": 42, "failed": 0, "skipped": 0 },
      "coverage": {
        "lines": { "covered": 1018, "total": 1152, "percent": 88.37 },
        "branches": { "covered": 110, "total": 162, "percent": 67.9 }
      },
      "warnings": { "restore": 0, "build": 3, "test": 1, "total": 4 }
    },
    "e2e": { "kind": "e2e", "tests": { "total": 20, "passed": 20, "failed": 0, "skipped": 0 } },
    "scan-api": {
      "kind": "scan",
      "vulnerabilities": {
        "bySeverity": { "critical": 0, "high": 0, "medium": 6, "low": 1, "negligible": 1, "unknown": 0 },
        "total": 8,
        "fixable": 0
      }
    }
  },
  "totals": {
    "tests": { "unit": { "total": 119, "passed": 119, "failed": 0, "skipped": 0 }, "e2e": { "total": 20, "passed": 20, "failed": 0, "skipped": 0 } },
    "warnings": 4,
    "vulnerabilities": { "bySeverity": { "critical": 0, "high": 14, "medium": 33, "low": 4, "negligible": 8, "unknown": 0 }, "total": 59, "fixable": 2 }
  }
}
```

- A component's name is its artifact name without `quality-`. `kind` is `unit`, `e2e` or `scan`.
- `warnings` counts unique warning lines per source, as the PR comment lists them.
- `tests`, `coverage`, `warnings` and `vulnerabilities` appear only when the component had reports of that kind.
- `percent` is `null` when there is nothing to cover (`total` 0).
- Adding fields is a compatible change. Renaming or removing one bumps `schemaVersion`.

## Formats read

| Kind | Formats |
|---|---|
| tests | TRX, JUnit XML, Vitest/Jest JSON (`numTotalTests`), Playwright JSON (`stats`) |
| coverage | Cobertura XML, Istanbul `coverage-summary.json` |
| scan | Grype JSON |
| warnings | `{"warnings": {"<source>": <count>}}` |

Within one component JUnit is preferred over Vitest JSON, and Cobertura over Istanbul, so a project
that writes both is not counted twice. Files of the same format add up, e.g. one TRX and one
Cobertura file per .NET test project. When two test projects cover the same assembly, its lines
count twice, so .NET line coverage is approximate.
