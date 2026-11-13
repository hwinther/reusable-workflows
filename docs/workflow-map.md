# Workflow map

How the reusable workflows link up across an app's lifecycle: pull request, merge to main, the
nightly run, release and production. Also covered: what each stage hands to the next (images, the
manifests artifact, test results). Drawn from ClutterStock's current workflows; skylens, romslig,
pbs-browser, ddnsadmin and test use the same shape with fewer images.
[consumer-topologies.md](consumer-topologies.md) has the smaller per-scenario examples.

```mermaid
flowchart LR
  A["reusable workflow<br/>this repo, job level"]:::rw
  B["composite action<br/>this repo, step level"]:::ca
  C["job in the app repo"]:::cj
  D["outside the run<br/>registry, other repo, cluster"]:::ext
  E["planned"]:::plan
  A ~~~ B ~~~ C ~~~ D ~~~ E
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
  classDef plan fill:#fef9c3,stroke:#ca8a04,color:#713f12,stroke-dasharray:4 3
```

Solid arrows are `needs:` or triggers, labelled with what travels along them. Dotted arrows are
data that is read later, by another run or another repo.

## The lifecycle

```mermaid
flowchart LR
  subgraph pr["pull request"]
    ci["ci.yml<br/>→ pr-build.yml"]:::rw
    pre["pr-e2e.yml<br/>build · scan · e2e<br/>preview with deploy-feature"]:::rw
    clean["pr-preview-cleanup.yml<br/>→ gitops-preview-teardown.yml"]:::rw
  end
  subgraph main["merge to main"]
    pm["pr-e2e.yml on push<br/>+ unit · push :main<br/>manifests:main · quality"]:::rw
  end
  subgraph night["every night"]
    np["nightly-preview.yml<br/>→ nightly-preview-e2e.yml"]:::rw
  end
  subgraph rel["release"]
    tr["tag-and-release.yml<br/>tag vX.Y.Z"]:::rw
    cont["container.yml on tag<br/>→ dotnet/docker-container.yml<br/>+ manifests:vX.Y.Z"]:::rw
    prom["promote.yml<br/>approve · co-sign"]:::cj
  end
  ghcr[("GHCR<br/>images · manifests · quality")]:::ext
  prox[("hwinther/proxmox<br/>Flux")]:::ext

  pre -->|"merge"| pm
  pre -.->|"preview overlay"| prox
  clean -.->|"remove overlay"| prox
  pm -->|"images, manifests:main,<br/>quality:main"| ghcr
  ghcr -.->|"manifests:main"| np
  np -.->|"nightly overlay, then teardown"| prox
  tr -->|"tag push"| cont
  cont -->|"signed release artifacts"| ghcr
  ghcr -.->|"test follows ref.semver"| prox
  prom -->|"production tag-bump PR"| prox
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

## `pr-e2e.yml`: pull requests and main

One workflow for both events. Each image is built once and handed on by reference: on same-repo
pull requests it goes to a staging tag (`pr-<N>-<sha7>`) as `repo@digest`, otherwise it is passed as
a workflow artifact. The scan, e2e and push all use those exact bytes. On pull requests the push,
manifests and preview steps run only with the `deploy-feature` label. On main they always run, and
`unit` and `quality` join in.

```mermaid
flowchart TD
  ver["version<br/>gitversion.yml"]:::rw
  unit["unit (main only)<br/>pr-build.yml"]:::rw
  subgraph build["build (parallel)"]
    bapi["api · migrator<br/>build-image-dotnet.yml"]:::rw
    bfe["frontend<br/>build-image-docker.yml"]:::rw
    be2e["e2e-image<br/>build-image-docker.yml<br/>FROM playwright-config:&lt;lock version&gt;"]:::rw
  end
  scan["api/migrator/frontend-scan<br/>scan-image.yml"]:::rw
  e2e["e2e<br/>playwright-e2e.yml<br/>compose stack + suite"]:::rw
  cov["coverage-summary<br/>e2e-coverage-summary.yml"]:::rw
  push["push-api/migrator/frontend<br/>image-push.yml<br/>sign · attest"]:::rw
  man["manifests<br/>manifests action<br/>render · push · sign"]:::ca
  dp["deploy-preview (PR)<br/>gitops-preview-upsert.yml"]:::rw
  q["quality (main)<br/>quality-artifact.yml"]:::rw
  prox[("hwinther/proxmox")]:::ext
  ghcr[("GHCR")]:::ext

  ver -->|"version"| build
  bapi -->|"image"| scan
  bfe -->|"image"| scan
  bapi -->|"image"| e2e
  bfe -->|"image"| e2e
  be2e -->|"image"| e2e
  scan --> push
  e2e --> push
  push -->|"pushed digests"| man
  man -->|"manifests digest"| dp
  dp -->|"overlay commit<br/>GitOps app token"| prox
  man --> ghcr
  push --> ghcr
  unit -. "quality-node · quality-dotnet" .-> q
  scan -. "quality-scan-*" .-> q
  e2e -. "quality-e2e" .-> q
  e2e -. "e2e-coverage" .-> cov
  unit -. "quality-node" .-> cov
  q -->|"quality:main-&lt;sha7&gt;, :main"| ghcr
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

`manifest-diff.yml` (pull requests) renders the manifests with the same action and comments the
diff against main.

## `nightly-preview-e2e.yml`: the whole suite through the real chain

The app repo's caller supplies the schedule, `app_name`, `health_path` and the secrets. Everything
else comes from defaults derived from the app name: host, preview path and manifests repository.

```mermaid
flowchart LR
  res["resolve<br/>manifests:main digest<br/>+ runner image from lock file"]:::rw
  clr["clear<br/>gitops-preview-teardown.yml"]:::rw
  gone["wait-gone<br/>health_path stops answering"]:::rw
  dep["deploy<br/>gitops-preview-upsert.yml<br/>pr_number: nightly"]:::rw
  e2e["e2e<br/>playwright-e2e.yml<br/>base_url = preview host"]:::rw
  td["teardown<br/>gitops-preview-teardown.yml"]:::rw
  rep["report (schedule)<br/>one issue while red"]:::rw
  edge[("OPNsense/NAXSI → Traefik → Authelia<br/>Flux signature check · CNPG db · netpols")]:::ext

  res --> dep
  clr --> gone --> dep --> e2e --> td --> rep
  dep -.-> edge
  e2e -.->|"browser + TOTP login"| edge
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

## Results: from test jobs to the pages that show them

Every job that produces results uploads them under a fixed name. Collector workflows turn them
into something people read. The yellow nodes are the proposed next step: a single transport for
the HTML reports as well, so GitHub Pages only assembles and builds nothing itself.

```mermaid
flowchart LR
  subgraph prod["producers (upload-artifact)"]
    nb["node-build<br/>quality-node<br/>JUnit · Vitest · Cobertura"]:::ca
    db["dotnet-build<br/>quality-dotnet<br/>TRX · Cobertura"]:::ca
    sc["_scan-image<br/>quality-scan-&lt;image&gt;<br/>Grype JSON"]:::ca
    pw["playwright-e2e.yml<br/>quality-e2e (results.json)<br/>e2e-coverage (monocart)"]:::rw
  end
  subgraph coll["collectors"]
    qa["quality-artifact.yml<br/>summary.json · details.json"]:::rw
    cs["e2e-coverage-summary.yml<br/>wshno-coverage-summary"]:::rw
  end
  subgraph pages["where it shows up"]
    oci[("ghcr …/quality:&lt;tag&gt;<br/>signed OCI")]:::ext
    dev["wshno/devops<br/>repository report"]:::ext
    prc["PR comment<br/>+ job summary"]:::cj
  end
  rep["report-* (HTML)<br/>Allure · monocart · Lighthouse · ZAP"]:::plan
  gp["GitHub Pages<br/>assembles only"]:::plan

  nb --> qa
  db --> qa
  sc --> qa
  pw --> qa
  nb --> cs
  pw --> cs
  qa --> oci
  qa -->|"quality-summary artifact"| dev
  cs --> prc
  rep -.-> qa
  oci -.-> gp
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
  classDef plan fill:#fef9c3,stroke:#ca8a04,color:#713f12,stroke-dasharray:4 3
```

## Release and production

```mermaid
flowchart TD
  disp["workflow_dispatch"]:::cj
  tag["tag-and-release.yml<br/>vX.Y.Z + GitHub release<br/>tag pushed as devops-bot"]:::rw
  cont["container.yml (on: push tags v*)<br/>dotnet-container.yml · docker-container.yml<br/>build at the tag · scan · push · sign"]:::rw
  man["manifests job<br/>manifests:vX.Y.Z, signed by container.yml@tag"]:::ca
  test[("test env<br/>OCIRepository ref.semver")]:::ext
  prom["promote.yml<br/>check signature · production approval<br/>co-sign · tag-bump PR"]:::cj
  prod[("production<br/>accepts only the promote signature")]:::ext

  disp --> tag -->|"tag push fires"| cont --> man
  man -.->|"new release"| test
  man -.-> prom
  prom -->|"PR merged in hwinther/proxmox"| prod
  classDef rw fill:#dbeafe,stroke:#3b82f6,color:#1e3a8a
  classDef ca fill:#dcfce7,stroke:#22c55e,color:#14532d
  classDef cj fill:#f3f4f6,stroke:#9ca3af,color:#111827
  classDef ext fill:#fee2e2,stroke:#ef4444,color:#7f1d1d,stroke-dasharray:4 3
```

Maintenance runs on its own schedules and doesn't link to the above. It covers `prune-ghcr.yml`
(staging tags of closed PRs, old versions), `prune-npm.yml`, `prune-nuget.yml`,
`dependabot-update-dotnet-lockfiles.yml`, `format-and-create-pr.yml` and `stryker.yml`.
