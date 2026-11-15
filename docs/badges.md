# Status badges

The `badges` composite action draws shields.io-style SVG badges with
[badge-maker](https://www.npmjs.com/package/badge-maker), the library shields.io runs. It draws
them locally, without the network. `pages-badges.yml` publishes them on the repo's GitHub Pages
site. Badges are never committed to the repo: a badge branch or checked-in SVGs grow the git
history with every run.

## Badges

| File | Input | Message | Colour |
|---|---|---|---|
| `tests-unit.svg`, `tests-e2e.svg` | `quality_summary` (`totals.tests`) | `284 passed`, or `3 failed, 281 passed` | brightgreen, red on any failure, grey with 0 passed |
| `warnings.svg` | `quality_summary` (`totals.warnings`: restore, build, test, typecheck, lint) | count | 0 brightgreen, under 10 yellow, otherwise orange |
| `vulnerabilities.svg` | `quality_summary` (`totals.vulnerabilities`, every scanned image) | `0C 13H 58M 10L`, or `clean` | red on a critical, orange on a high, yellow on a medium, otherwise brightgreen |
| `coverage-backend.svg`, `coverage-frontend.svg` | `quality_summary` (line coverage of the `dotnet` and `node` components), or `backend_*`/`frontend_*` | percent | coverage scale |
| `coverage-backend-branches.svg`, `coverage-frontend-branches.svg` | `quality_summary` (branch coverage) | percent | coverage scale |
| `coverage-combined.svg` | `quality_summary` (`totals.coverage.combined`: unit and e2e lines merged per file) | percent | coverage scale |
| `coverage-e2e.svg` | `e2e_cobertura` | percent | coverage scale |
| `lighthouse-{performance,accessibility,best-practices,seo}.svg` | `lighthouse_json` | score | coverage scale |
| `nightly-e2e.svg` | `nightly_status` | `success`, `failure`, `cancelled` | brightgreen, red, grey |
| `security-zap.svg` | `zap_json` | `0H 2M 5L`, or `clean` | red on a high, orange on a medium, yellow on a low |

Unit components other than `dotnet` and `node` (`python`, `go`) keep their component name, e.g.
`coverage-python.svg`. An explicit coverage input wins over the summary's line coverage.

Coverage scale (shields.io's): under 50 red, under 60 orange, under 70 yellow, under 80
yellowgreen, under 90 green, otherwise brightgreen.

## Publishing with pages-badges.yml

For a repo without a Pages site of its own:

1. Settings > Pages > Source: **GitHub Actions**.
2. Add `.github/workflows/badges.yml`:

   ```yaml
   name: Badges

   on:
     workflow_run:
       workflows: ["E2E"]   # the workflow that calls quality-artifact.yml on main pushes
       types: [completed]
       branches: [main]

   permissions: {}

   jobs:
     badges:
       # Pushes only (a fork's branch can be called main too). A failed run counts, so failed tests turn the badge red.
       if: github.event.workflow_run.event == 'push' && contains(fromJSON('["success", "failure"]'), github.event.workflow_run.conclusion)
       permissions:
         actions: read
         pages: write
         id-token: write
       uses: hwinther/reusable-workflows/.github/workflows/pages-badges.yml@<sha> # vX.Y.Z
       with:
         quality_run_id: ${{ github.event.workflow_run.id }}
   ```

3. Add the badges to the README (`<owner>` lowercase):

   ```markdown
   | | |
   |---|---|
   | **Tests** | ![Unit tests](https://<owner>.github.io/<repo>/badges/tests-unit.svg) ![E2E tests](https://<owner>.github.io/<repo>/badges/tests-e2e.svg) ![Warnings](https://<owner>.github.io/<repo>/badges/warnings.svg) |
   | **Coverage** | ![Backend](https://<owner>.github.io/<repo>/badges/coverage-backend.svg) ![Frontend](https://<owner>.github.io/<repo>/badges/coverage-frontend.svg) ![Frontend unit+e2e](https://<owner>.github.io/<repo>/badges/coverage-combined.svg) |
   | **Security** | ![Image vulnerabilities](https://<owner>.github.io/<repo>/badges/vulnerabilities.svg) |
   ```

   The site's index page (`https://<owner>.github.io/<repo>/`) lists every published badge with its
   Markdown.

Pages replaces the whole site on each deploy. The workflow reads `badges/index.json` from the live
site and carries forward every badge it lists, so a badge rendered by another workflow survives.
Another workflow (a nightly run, a scan) publishes its own badges by uploading the SVGs as an
artifact and calling `pages-badges.yml` in the same run with `extra_badges_artifact`. That run has
no quality summary, so the summary badges are carried forward unchanged.

Pages on a private repo needs a paid plan, and the site is public even then (private Pages is
Enterprise Cloud only). The badges themselves reveal little, but don't put reports with source
code on such a site.

## Inside an existing Pages site

A repo that already builds a Pages site calls the action in its own build and copies the
directory into the site:

```yaml
- uses: hwinther/reusable-workflows/.github/actions/badges@<sha> # vX.Y.Z
  with:
    quality_summary: quality-summary/summary.json
    backend_summary_json: dotnet-summary/Summary.json
    lighthouse_json: lighthouse/lighthouse-home.json
    out: site/badges
```
