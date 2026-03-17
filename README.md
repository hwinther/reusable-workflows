# reusable-workflows

Reusable workflows, build and deploy for node, dotnet and python

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
