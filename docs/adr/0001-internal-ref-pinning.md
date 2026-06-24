# ADR 0001 — Freeze internal `uses:` refs to immutable tags at release time

- **Status:** Accepted — mechanism implemented 2026-06-24 on `v2-coordinated-release`.
  Pending operational steps before relying on it: (1) enable tag immutability
  (immutable releases or a ruleset), (2) cut `v2.0.0` so a frozen tag exists, then
  (3) point consumers at the non-floating `v2.0.0`.
- **Date:** 2026-06-24
- **Supersedes / relates to:** the single-semver model in `CLAUDE.md`, enforced by
  `scripts/validate-version-refs.mjs`
- **Scope note:** This is **consumer-non-breaking** (it changes how the repo
  *releases*, not its public input/output surface), so it does **not** require a
  major bump. It is independently shippable as a minor once `v2` has landed. Treat it
  as its own focused change, not part of the v2 release.

## Context

Internal references in this repo all use the **floating major tag**, e.g.
`uses: hwinther/reusable-workflows/.github/actions/_scan-image@v2`, including
action→action refs (`node-build` → `_format-output@v2`,
`_scan-image` → `_grype-summary@v2`, `_build-image-dotnet` →
`_dotnet-add-nuget-source@v2`).

When a consumer pins a reusable workflow to a commit SHA
(`uses: …/docker-container.yml@<SHA>`), GitHub checks out *that workflow file* at
that SHA — but the file still contains the literal string `_scan-image@v2`, which is
resolved against the **`v2` git ref at run time**, not against the consumer's pinned
SHA. Consequences:

- **Supply chain:** a consumer who SHA-pins the workflow still executes whatever `v2`
  resolves to for every action underneath. Moving `v2` (compromise, or a routine
  release) changes their "pinned" run. This is the tj-actions/reviewdog class of
  incident (March 2025): pinning one layer while a transitively-floating tag beneath
  it is repointed.
- **Feature pinning:** no single commit fully determines behaviour, so "we try not to
  break it" is the only guarantee on offer. There is no *mechanical* one.

### Options considered

1. **Status quo** — accept the float. Cheapest, but leaves the gap above.
2. **Split actions into a separate `reusable-actions` repo, SHA-pinned.** Rejected:
   the churn comes from dependency **depth** (layer N must reference an immutable
   layer N−1, which must exist first), which is identical in one repo or two — the
   second repo only adds cross-repo release coordination on top. It also moves the
   already-directly-consumed `sign-image`/`verify-image`, which *would* be a breaking
   change. No net benefit over single-repo pinning.
3. **Pin-on-`main` (always immutable internal refs).** `main` is always fully pinned;
   every cross-layer change pays its ripple as commits when made. Simplest mental
   model, but the leaf-action ripple is real day-to-day friction. Example: editing
   `_format-output` (used 3× by `node-build`, 3× by `dotnet-build`) forces bumping
   `node-build` and `dotnet-build`, then `pr-build.yml` — ~3 commits per leaf edit.
   `_dotnet-add-nuget-source` has 5 direct callers, so its ripple is wider.
4. **Freeze-at-release with immutable patch-tag internal refs (this ADR).** Develop
   on floating `@v{major}`; the release workflow rewrites internal refs to the
   immutable `@vX.Y.Z` patch tag in a single commit and tags it.

## Decision

Adopt **option 4**. Day-to-day development continues to use floating
`@v{major}` internal refs on `main` (atomic edits, no chicken-and-egg). At release
time, `tag-and-release.yml` produces a **frozen release commit** whose internal refs
are all rewritten to the immutable patch tag being cut, then tags that commit.
Consumers pin to the immutable `@vX.Y.Z` (recommended) or a SHA for full transitive
reproducibility; `@v{major}` consumers still float across releases but, within any
single release, get a commit whose internals are pinned.

### The single-commit "self-reference" trick

The whole layer chain collapses into **one commit** because the tag is created
*after* the commit:

1. Compute the next version (e.g. `v2.3.5`) — `tag-and-release.yml` already does this
   in `auto` mode.
2. Rewrite every internal ref `…/reusable-workflows/.github/<path>@v2`
   → `…@v2.3.5` across `.github/`.
3. Commit the rewrite (the tag `v2.3.5` does not exist yet).
4. Create the annotated tag `v2.3.5` pointing at that commit.

Now `_grype-summary@v2.3.5`, `_scan-image@v2.3.5`, `docker-container.yml@v2.3.5`, etc.
all resolve to that one commit — self-consistent, no topological commit chain. (A
**SHA** freeze cannot do this in one commit, because each commit's SHA must exist
before the next layer can reference it; that is the only reason this ADR prefers
immutable tags over SHAs — see Consequences.)

### The load-bearing dependency: tag immutability

With `@vX.Y.Z` internal refs, the immutability of that tag is **load-bearing**: if
`v2.3.5` could be force-moved, even a workflow-SHA-pinning consumer would be affected
(their pinned workflow file still says `_scan-image@v2.3.5`). Therefore the patch
tags must be made immutable:

- Enable **GitHub immutable releases** for the repo. The `vX.Y.Z` tags are published
  as Releases (they already are), so they become immutable; the bare floating tags
  (`v2`, `v2.3`) are **not** Releases and stay movable — which is exactly what we
  need, since `tag-and-release.yml` force-moves the floating tags every release.
- **And/or** a tag-protection ruleset that blocks update/delete on the immutable
  pattern only. The pattern must distinguish movable floats from immutable patches:
  - immutable: `v[0-9]*.[0-9]*.[0-9]*` (e.g. `v2.3.5`) — protect
  - movable: `v[0-9]*` and `v[0-9]*.[0-9]*` (e.g. `v2`, `v2.3`) — leave unprotected

If neither protection is enabled, the guarantee degrades to "convention." Do not ship
this ADR without one of them.

## Implementation plan

### 1. `tag-and-release.yml` — freeze step ✅ done

A `Freeze internal refs to <tag>` step runs after the "new commits" guard and before
`Create tag(s)`, gated on `github.repository == 'hwinther/reusable-workflows'` (only
this repo has self-refs, and the helper scripts only exist in its own checkout — a
consumer calling this via `workflow_call` gets the *consumer's* checkout). It:

1. skips unless `FULL_TAG` matches `vX.Y.Z`;
2. runs `node scripts/freeze-internal-refs.mjs --tag "$FULL_TAG"`;
3. runs `node scripts/validate-version-refs.mjs --release` as a pre-tag gate (aborts
   the release if any floating ref survived);
4. if anything changed, `git checkout --detach` then commits the frozen refs. The
   existing `Create tag(s)` step then tags `HEAD` (= the freeze commit) and force-moves
   the floating `vX`/`vX.Y` tags onto it. `main` is never pushed, so it stays on
   `@v{major}`; the freeze commit reaches the remote only via the pushed tag.

`scripts/freeze-internal-refs.mjs` rewrites `uses: <slug>/.github/…@v{major}` (and
`@v{major}.{minor}`) → `@<tag>`; three-part refs, SHAs, third-party pins, and `# vX.Y.Z`
comments are left untouched.

### 2. `scripts/validate-version-refs.mjs` — release mode ✅ done

- **Default mode (`main` / PRs):** unchanged — v-prefixed self-refs must match
  `.version-major`; `@main`/`@HEAD`/`@master` rejected.
- **`--release` (or `VALIDATE_MODE=release`):** every self-ref must be immutable — a
  full `vX.Y.Z` tag (major must match) or a 40-hex SHA; a floating `@v{major}` /
  `@v{major}.{minor}` is an error. Mechanical proof the freeze worked.

### 3. Repo settings (one-time) — ⏳ remaining

- Turn on **immutable releases**, or add the tag-protection ruleset described above
  (protect `v*.*.*`, leave `v*` and `v*.*` movable).

### 4. Docs

- Update `CLAUDE.md`: internal refs are `@v{major}` **on `main`** and frozen to the
  immutable patch tag **at release**; describe the freeze step and the validator's two
  modes.
- Update `README.md` / `docs/consumer-topologies.md`: recommend consumers pin
  `@vX.Y.Z` for full transitive reproducibility (note `@v{major}` still floats across
  releases but is internally consistent within one).

## Consequences

### Positive
- A released, tagged commit fully determines all transitive action/workflow code.
  Consumers pinning `@vX.Y.Z` (or a SHA) get reproducible, tamper-evident runs.
- The floating-tag attack surface shrinks to the *development* line on `main`, which
  no one should consume — released artifacts carry no floating internal refs.
- Near-zero authoring churn: contributors keep editing with `@v{major}`; the ripple is
  paid once, automatically, in a single release commit.
- No consumer-facing API change → shippable as a minor.

### Negative / caveats
- **Tag immutability is load-bearing** (see above). The repo *must* enable immutable
  releases or a tag ruleset; otherwise `@vX.Y.Z` internal refs are only as good as
  convention. This is the deliberate trade vs SHA pinning, which is cryptographically
  immutable but needs an N-commit topological freeze instead of one commit.
- The release tag points at a **derived commit** that is a child of the released
  `main` commit but not on the `main` branch. `git log v2` shows one extra
  "freeze" commit. Harmless for consumers (they fetch by ref); document it for
  maintainers.
- `tag-and-release.yml` gains commit-rewriting logic and needs `contents: write`
  (already held). The "refuse to tag if HEAD is already the latest tag" guard must be
  evaluated against the released `main` commit, not the freeze commit.

### If stronger guarantees are needed later
Switch the freeze target from `@vX.Y.Z` to **commit SHAs**. Same model, but the
freeze becomes an N-commit topological chain (leaf actions first) instead of one
commit, removing the dependency on tag protection. Everything else (validator modes,
develop-on-`@v{major}`, release-only freeze) is unchanged.

## Verification

- After implementing, cut a test release and run `validate-version-refs.mjs
  --mode=release` against the tag → must report zero `@v{major}` internal refs.
- Check out the tag and resolve one deep chain by hand
  (`docker-container.yml@vX.Y.Z` → `_scan-image@vX.Y.Z` → `_grype-summary@vX.Y.Z`):
  all three must resolve to the single freeze commit.
- Attempt to force-move the patch tag → must be rejected by the ruleset / immutable
  releases setting.
- Confirm `v{major}` / `v{major}.{minor}` floating tags still move on the next
  release (not blocked by the protection pattern).
