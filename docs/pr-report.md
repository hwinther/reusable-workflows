# PR report: one comment for a commit's reports

Builds, tests, image scans, e2e runs and previews each used to post their own PR comment, from
different workflows. `pr-report.yml` replaces them with one comment per PR:

```
## 🧾 PR status — `abc1234`

| Check | Result | Run |
|---|---|---|
| ✅ Build · .NET (Backend.slnx) | passed · 51/51 tests · 🟢 84.2 % lines | run |
| ⚠️ Build · Node (src/frontend) | 129/129 tests · 🟡 71.5 % lines · 3 warnings | run |
| ⚠️ Image scan · api | warnings · 0 critical, 2 high | run |
| ✅ E2E (Playwright) | passed · 34/34 tests · 2m 10s | run |
| ℹ️ Frontend coverage (unit + e2e) | unit 🟡 71.5 % · e2e 🟡 54.0 % · combined 🟢 82.3 % (+10.8 from e2e) | run |

▸ ✅ Build · .NET (Backend.slnx)        (collapsed)
▾ ⚠️ Image scan · api                    (open: needs attention)
```

## How it works

1. A job adds a **section** with the `pr-report-section` action: an id, a title, a status, an
   optional one-line summary and a markdown body. The action uploads them as the artifact
   `pr-report-<id>` (`status.json` + `report.md`).
2. The repo has a small workflow triggered by `workflow_run` on the workflows that add sections.
   It calls `pr-report.yml`, which finds every `pull_request` run for the PR's head commit,
   downloads their `pr-report-*` artifacts and renders the comment: a table, then one collapsible
   section per report, open when its status is not success, skipped or neutral. Workflows still
   running are listed as ⏳.
3. Each run renders the whole comment again from the artifacts, so runs for the same commit can
   cancel each other (`cancel-in-progress`), and nothing is lost. A run for a commit the PR has
   moved past does nothing. A section uploaded again (a re-run) replaces the earlier one.

`workflow_run` runs with the base repository's token, so the comment is also posted on fork and
Dependabot PRs. The sections come from PR runs and are only parsed (jq) and shown as markdown.

## Set up a repository

The caller workflow (it must be on the default branch before `workflow_run` fires):

```yaml
name: PR report
on:
  workflow_run:
    workflows: [CI, Container, PR e2e]   # the names of the workflows that add sections
    types: [completed]
permissions: {}
jobs:
  report:
    if: github.event.workflow_run.event == 'pull_request'
    permissions:
      actions: read
      contents: read
      pull-requests: write
    uses: hwinther/reusable-workflows/.github/workflows/pr-report.yml@<sha> # vX.Y.Z
```

Then turn sections on where they come from. For `pr-build.yml`:

```yaml
    with:
      pr_report_enabled: true
```

Each build becomes a section (`build-node-<dir>`, `build-dotnet-<solution>`, …) instead of its own
comment. For .NET and Node its table line sums the build up: failures first (`2 build errors`,
`build exit 137 (killed)`, `3/129 tests failed`), otherwise tests, line coverage (summed over the
Cobertura files) and warnings; warnings alone make it ⚠️ while the build still passes. The gate adds a `build` section when no build ran (no relevant changes, a draft, or a
failed change detection).

The e2e workflows take the same input: `playwright-e2e.yml` with `pr_report_enabled: true` adds the
`e2e` section (tests, flaky, duration; or which compose services kept the stack down), and
`e2e-coverage-summary.yml` adds `coverage-frontend` (unit, e2e and combined line coverage, and how
much e2e adds), both in place of their own comments.

Coverage is coloured 🔴 below 40 %, 🟡 below 80 % and 🟢 from 80 %; change it with
`coverage_thresholds: "50 90"` on `pr-build.yml` and `e2e-coverage-summary.yml`. The colour is
informational and never changes a section's status.

A job of your own adds a section like this:

```yaml
      - name: Add the scan to the PR report
        if: always() && github.event_name == 'pull_request'
        uses: hwinther/reusable-workflows/.github/actions/pr-report-section@<sha> # vX.Y.Z
        with:
          id: image-scan-api
          title: Image scan · api
          status: ${{ steps.scan.outcome }}
          summary: 0 critical, 2 high
          content_file: ${{ runner.temp }}/grype-summary.md
          order: "30"
```

Order conventions: 10 build, 20 tests, 30 image scan, 40 e2e, 50 preview.

## Notes

- Comments the repo posted before switching (`build-results-node` and friends) stay on open PRs
  until those PRs close.
- The comment is cut below GitHub's size limit by `_sticky-pr-comment`, and each section body is
  capped at 12 000 characters with a link to its run; the job summaries keep the full reports.
- Changes to the caller only take effect once merged, since `workflow_run` reads it from the
  default branch. `pr-report.yml` also takes `head_sha` and `pr_number`, to run it by hand from a
  `workflow_dispatch` caller when debugging.
