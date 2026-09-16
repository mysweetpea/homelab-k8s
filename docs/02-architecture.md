# 02 — Architecture

```
                        ┌────────────────────────────────────────────┐
   you / family         │                YOUR MACHINE                │
  phones · laptops      │  k3s (lightweight Kubernetes, 1 node+)     │
        │               │                                            │
        ▼               │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
  ┌──────────────┐      │  │ Jellyfin │  │Immich    │  │Vaultwarden│ ...56 apps
  │   Traefik    │──────┼─▶│ (movies) │  │(photos)  │  │(passwords)│  │
  │  (front door)│      │  └──────────┘  └──────────┘  └──────────┘  │
  └──────┬───────┘      │        every app has replicas + storage    │
         │              │  ┌──────────────────────────────────────┐  │
  Authentik SSO ◀───────┼──│ one login for all of the above       │  │
         │              │  └──────────────────────────────────────┘  │
         ▼              │  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
  internet (optional)   │  │ ArgoCD   │  │ Longhorn │  │ Grafana  │  │
  Cloudflare Tunnel ────┼─▶│ keeps it │  │ replicates│ │ watches  │  │
                        │  │ in sync  │  │ your data │ │ it all   │  │
                        │  └──────────┘  └──────────┘  └──────────┘  │
                        └────────────────────────────────────────────┘
```

## The five layers

### 1. Foundation
**k3s** — a certified, lightweight Kubernetes. Single node works; add nodes later and Longhorn
replicates data between them. **MetalLB** hands services real IPs on your LAN; **Traefik** (bundled
with k3s) routes domains → apps; **cert-manager** is available for internal PKI.

### 2. State
**ArgoCD** continuously reconciles the cluster against manifests in this repository (GitOps).
If something drifts or dies, it is restored automatically. **argocd-image-updater** tracks upstream
releases (semver) and rolls out new versions without human action.

### 3. Data
**Longhorn** provides replicated block storage for every app's PVC, nightly snapshots, and (when
configured) encrypted offsite backups. Databases (PostgreSQL) back the stateful apps.

### 4. Access & identity
**Authentik** is the SSO hub — OIDC for apps that support it, forward-auth middleware for those
that don't, LDAP for legacy clients. Public exposure is via **Cloudflare Tunnel** (no open ports)
or your own DNS; **network policies** isolate zones (dmz / private / monitoring) so a compromised
pod cannot wander.

### 5. Operations
**Grafana + Loki** (logs), **Netdata** (per-node health), **Uptime Kuma** (service monitors with
phone push alerts), **Gotify/iGotify** (self-hosted notifications), **restic + Longhorn backups**
on a nightly schedule with failure alerting.

## Installer architecture

The installer (`installer/`) is a layered bash product:

```
wizard.sh ──▶ plan file ──▶ deploy.sh ──▶ install.sh engine / appliance renderer
    │                            │
    ├─ lib/ui.sh        (TUI ladder: fzf → whiptail → ANSI → plain)
    ├─ lib/catalog.sh   (54 apps: deps, use-cases, RAM, secrets — strict validation)
    ├─ lib/github.sh    (device-flow auth, fork, push, upstream sync)
    └─ lib/appliance.sh (no-GitHub renderer: upstream $values + inline valuesObject
                         + in-cluster image write-back)
```

Two deployment methods fall out of one engine:

- **Appliance** — Applications are rendered with `spec.sources[1]` ($values ref) re-pointed at the
  upstream repo, user choices injected as `spec.sources[0].helm.valuesObject` (top ArgoCD
  precedence), and image-updater annotations flipped from `git` to `argocd` write-back so updates
  patch the Application CR in-cluster. Zero user-owned git.
- **GitOps** — the user's fork is created via GitHub device-flow (`gh`), repoURLs rewritten to it,
  changes committed and pushed; ArgoCD then manages everything from the user's own repo.

Both keep ArgoCD as the reconciler — neither is "imperative installs that drift".

## Testing

126 assertions across 7 suites (`installer/test/`), all runnable offline:

| Suite | Covers |
|---|---|
| test-catalog | parsing, validation, dependency closure, cycle detection |
| test-ui | every TUI backend + plain/ANSI parity + cancel/EOF safety |
| test-wizard | full guided + expert flows via scripted stdin, plan-file correctness |
| test-github | fork/push/sync against local bare repos (no network) |
| test-appliance | render transforms on real app manifests (all 56 validated) |
| test-provision | hardware sanity, idempotence, MetalLB manifest shape |
| test-deploy | plan consumption, method handoff, secret generation, manage script |

CI (`.github/workflows/installer-lint.yml`) reruns all of it on real Linux, plus a CRLF guard and
an ephemeral k3s-in-docker end-to-end job — because two portability bugs (CRLF scripts, Windows
path collapse in git) were found the hard way and must never ship again.
