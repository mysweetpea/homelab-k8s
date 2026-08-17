# ArgoCD Image Updater — Automated Container Updates

This component keeps the cluster's container images **current automatically**:
it watches for new versions, updates the Helm values in this repo, commits the
bump, and ArgoCD rolls it out. No manual version-pinning, no "it's been months
since we updated."

## How it works

```
Registry (Docker Hub / GHCR) ──► Image Updater ──► git commit (values.yaml bump)
        ▲                                              │
        └──────────── ArgoCD syncs new image ◄──────────┘
```

1. The controller polls configured registries for new tags matching each
   app's update strategy (semver, or newest-build for rolling tags).
2. When a new version is found, it **commits the version bump back to this
   repo** (git write-back via SSH key) — the change is reviewable in Git
   history, exactly like a human-made change.
3. ArgoCD detects the drift and rolls out the new image.

## Configuration

The controller is **CR-driven** (v1.2.1): the `ImageUpdater` custom resource in
`values.yaml` (`extraObjects`) defines everything. Each app entry specifies:

- **`imageName`** — the image to watch (e.g. `n8nio/n8n`)
- **`updateStrategy`** — `semver` for versioned releases, `newest-build` for
  rolling tags
- **`allowTags`** — a regex whitelist (e.g. `^2\.\d+\.\d+$` for n8n v2.x)
- **`manifestTargets.helm`** — where in `values.yaml` the repository/tag live
- **`writeBackConfig.writeBackTarget`** — which `values.yaml` file to commit to

The CR covers **30+ apps / 30+ images** across all zones.

## Lessons learned (the hard way)

This component has a history of subtle failure modes, all documented in the
`values.yaml` comments:

1. **CRD defaults are dangerous** — the CRD defaults `writeBackConfig.method`
   to `argocd` (live-spec-only). Without an explicit per-app
   `method: git:secret:argocd/ssh-git-creds`, the controller updates the live
   spec but **never commits to Git** — and ArgoCD's `selfHeal` reverts it.
2. **Multi-source apps ignore `.argocd-source-*.yaml`** — an earlier config
   wrote overrides that ArgoCD ignores for multi-source apps (sources[] +
   `$values`), so commits landed in Git but **no rollouts ever happened**
   (live images stayed old: gotify 2.6.1, n8n 2.33.6).
3. **The SSH key secret must be named `ssh-git-creds`** — the chart's default
   mount path is `/app/ssh-keys/id_rsa` with `subPath: sshPrivateKey`. The old
   name `argocd-image-updater-git-ssh` was never mounted → silent fallback to
   live-spec updates.
4. **Charts with default image registries** — `imageName` must be bare
   (`grafana/grafana`, `library/nextcloud`), not `docker.io/...`, or the chart
   renders `docker.io/docker.io/...` → ImagePullBackOff.

## Verification

```bash
argocd-image-updater list
```

The repo's commit history shows 100+ `automatic update` commits — the system
is working continuously.
