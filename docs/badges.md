# Status badges

The `badges` composite action draws shields.io-style SVG badges with
[badge-maker](https://www.npmjs.com/package/badge-maker), the library shields.io runs. It draws
them locally, without the network. `pages.yml` publishes them on the repo's GitHub Pages site
(layer `badges`, see [pages.md](pages.md)). Badges are never committed to the repo: a badge branch or checked-in SVGs grow the git
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

## README snippet

`<owner>` is lowercase. The site's index page (`https://<owner>.github.io/<repo>/`, when no layer
brings its own `index.html`) lists every published badge with its Markdown.

```markdown
| | |
|---|---|
| **Tests** | ![Unit tests](https://<owner>.github.io/<repo>/badges/tests-unit.svg) ![E2E tests](https://<owner>.github.io/<repo>/badges/tests-e2e.svg) ![Warnings](https://<owner>.github.io/<repo>/badges/warnings.svg) |
| **Coverage** | ![Backend](https://<owner>.github.io/<repo>/badges/coverage-backend.svg) ![Frontend](https://<owner>.github.io/<repo>/badges/coverage-frontend.svg) ![Frontend unit+e2e](https://<owner>.github.io/<repo>/badges/coverage-combined.svg) |
| **Security** | ![Image vulnerabilities](https://<owner>.github.io/<repo>/badges/vulnerabilities.svg) |
```

## Inside a site you build yourself

A repo that assembles its own Pages site calls the action in its build and copies the directory in:

```yaml
- uses: hwinther/reusable-workflows/.github/actions/badges@<sha> # vX.Y.Z
  with:
    quality_summary: quality-summary/summary.json
    backend_summary_json: dotnet-summary/Summary.json
    lighthouse_json: lighthouse/lighthouse-home.json
    out: site/badges
```

Badges from such inputs can also go through `pages.yml`: render them into a directory, upload it as
an artifact and add the layer `artifact:<name>=badges`.
