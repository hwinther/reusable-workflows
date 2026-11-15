# GitHub Pages: pages.yml

`pages.yml` builds a repo's GitHub Pages site from **layers** and deploys it. One `layers` input
says what goes where, so a badges-only repo, a repo with plain HTML docs and a repo with reports
from several workflows all use the same workflow with different lines. There are no per-feature
switches.

## Layers

One per line, `<kind>[:<source>][=<site-path>]`. A `#` starts a comment.

| Line | Content |
|---|---|
| `badges` / `badges:<run-id>` | Status badges ([badges.md](badges.md)) from the `quality-summary` artifact of that run (default: the calling run), in `badges/` |
| `dir:<repo-path>=<site-path>` | A directory of the repo at the calling ref, e.g. plain HTML |
| `artifact:<name>=<site-path>` | An artifact of the calling run, e.g. a coverage report a job uploaded |

`<site-path>` is relative, without `..`; `.` is the site root. The root layer goes in first, the
others in order, so a later layer wins where two overlap. Site path `badges` is special: the
directory's SVGs (lowercase `<name>.svg`) merge into the badges, next to the summary badges.

```yaml
with:
  layers: |
    badges:${{ github.event.workflow_run.id }}
    dir:docs/site=.                       # landing page and docs
    artifact:coverage-node=coverage-node
    artifact:nightly-badges=badges        # more SVGs into badges/
```

## Several workflows, one site

Pages replaces the whole site on every deploy. So every deploy writes `site-manifest.json` at the
site root with the files of each layer:

```json
{
  "schemaVersion": 1,
  "repository": "owner/app",
  "updatedAt": "2026-11-15T12:00:00Z",
  "layers": {
    ".": ["css/site.css", "index.html"],
    "badges": ["coverage-backend.svg", "tests-unit.svg"],
    "reports/coverage": ["index.html"]
  }
}
```

On the next deploy:

- a layer this run provides **replaces** the published one, so files that are gone disappear;
- a layer this run does not mention is **carried forward** file by file from the live site;
- badges **merge per file**: the published SVGs stay, this run's SVGs replace their namesakes.

So each workflow publishes only what it owns. For example, E2E publishes `badges`, a nightly run
publishes its report and `artifact:nightly-badges=badges`, and a docs workflow publishes
`dir:docs/site=.`. `carry_forward: false` publishes exactly this run's layers and drops the rest,
which is how a layer is removed.

All callers share the concurrency group `pages-<owner>/<repo>`, and reading the manifest and the
deploy run in one job. So two workflows can't overwrite each other's update. GitHub keeps one
pending run per group: a third run that arrives while one is waiting replaces the waiting one, and
the replaced workflow's layers arrive with its next run.

Carry-forward fetches every file of a layer over HTTPS. That suits HTML, docs and reports of a few
hundred files. A large report that changes every night is better published by the workflow that
produces it on every run.

## Caller

```yaml
name: Pages

on:
  workflow_run:
    workflows: ["E2E"]   # the workflow that calls quality-artifact.yml on main pushes
    types: [completed]
    branches: [main]

permissions: {}

jobs:
  pages:
    # Pushes only (a fork's branch can be called main too). A failed run counts, so failed tests turn the badge red.
    if: github.event.workflow_run.event == 'push' && contains(fromJSON('["success", "failure"]'), github.event.workflow_run.conclusion)
    permissions:
      actions: read     # artifacts and the quality summary
      contents: read    # dir: layers
      pages: write
      id-token: write
    uses: hwinther/reusable-workflows/.github/workflows/pages.yml@<sha> # vX.Y.Z
    with:
      layers: badges:${{ github.event.workflow_run.id }}
```

Plain HTML from the repo:

```yaml
on:
  push:
    branches: [main]
    paths: ["docs/site/**"]
jobs:
  pages:
    permissions: { actions: read, contents: read, pages: write, id-token: write }
    uses: hwinther/reusable-workflows/.github/workflows/pages.yml@<sha> # vX.Y.Z
    with:
      layers: dir:docs/site=.
```

When no layer brings an `index.html` for the root, the workflow writes one that links the layers
and lists the badges with their Markdown.

## Setup and limits

- Settings > Pages > Source: **GitHub Actions**. The `github-pages` environment allows the default
  branch by default; a `workflow_run` run is on the default branch.
- Pages on a private repo needs a paid plan, and the site is public even then (private Pages is
  Enterprise Cloud only). Badges reveal little, but don't publish reports that contain source code
  from a private repo.
