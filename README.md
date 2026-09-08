# MySweetPea Homelab — Kubernetes GitOps

[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.36.1-326CE5?logo=kubernetes&logoColor=white)](https://k3s.io)
[![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo&logoColor=white)](https://argo-cd.readthedocs.io/)
[![Services](https://img.shields.io/badge/Apps-55-8FAFB5)](#what-runs-on-it)
[![Secrets](https://img.shields.io/badge/Sealed_Secrets-55-00A98F?logo=sealedsecrets)](#secrets-management)
[![SSO](https://img.shields.io/badge/SSO-Authentik-8A2BE2)](https://goauthentik.io)
[![Storage](https://img.shields.io/badge/Storage-Longhorn_3--2--1-00A98F?logo=longhorn&logoColor=white)](#backups--disaster-recovery)
[![Self-hostable](https://img.shields.io/badge/Self--host-installer-2EA44F)](installer/)

A self-hosted, GitOps-managed Kubernetes cluster running **55 applications** —
privacy-first alternatives to everyday cloud services, an on-demand media
platform, and a full observability stack — for the MySweetPea community.

**Live site:** https://mysweetpea.cc · **Status:** https://status.mysweetpea.cc
**Website repo:** https://github.com/mysweetpea/portfolio

> 🛠️ **Want to run this yourself?** Most of this stack is reusable — see the
> [self-hosting installer](installer/). It deploys any subset of these services
> to your own cluster, generates your own secrets, and rewires the domain.

---

## Architecture

![Architecture diagram](docs/architecture.svg)

| | |
|---|---|
| **Cluster** | 3-node K3s v1.36.1 (Ubuntu 26.04), Flannel CNI |
| **Ingress** | Traefik + MetalLB (LAN load-balancer pool `.210–.240`) |
| **External access** | Cloudflare Tunnel — **zero inbound ports open** |
| **Storage** | Longhorn (2-replica, 40 volumes) + shared media PVC |
| **GitOps** | ArgoCD app-of-apps + Image Updater (auto-commits version bumps) |
| **Identity** | Authentik SSO — OIDC + LDAP + proxy outposts |
| **Network policy** | 40 NetworkPolicies, default-deny across 3 zones |
| **Secrets** | 55 SealedSecrets — encrypted at rest in this public repo |
| **Observability** | Grafana + Loki + Promtail, Netdata, Uptime Kuma (48 monitors), Homepage |

### Hardware

| Node | Role | Specs |
|------|------|-------|
| `k3s-master` | control-plane | Proxmox VM (OptiPlex) · 8 vCPU · 16 GB · 120 GB |
| `k3s-worker-a` | worker | EliteBook 745 G5 · 8 vCPU · 10 GB · 240 GB |
| `k3s-worker-b` | worker | EliteBook 840 G6 · 8 vCPU · 24 GB · 470 GB |
| Oracle VPS | egress + perf layer | ARM · nginx TLS edge, brotli, cache warmers, Longhorn backup target (150 GB volume) |

The network is split into **3 VLAN zones** (OpenWrt): management, DMZ, and
trusted — with the cluster adding its own default-deny layer on top.

---

## What is this?

MySweetPea is a small community platform: self-hosted alternatives to everyday
cloud services (password manager, media, files, photos, notes, AI chat, private
search, Matrix chat), funded by one-time contributions instead of subscriptions.

This repository is the **single source of truth** for that infrastructure.
Every service, policy, and secret is declared as code — if it isn't in this
repo, it doesn't exist.

### Why GitOps?

1. **Reviewable** — every change is a commit; nothing happens silently.
2. **Auditable** — full infrastructure history preserved in Git.
3. **Recoverable** — the entire stack can be rebuilt from this repo (and has
   been tested against that bar: backups capture the sealed-secrets key).

ArgoCD continuously reconciles live state against this repo; hand-made changes
on the cluster are reverted.

---

## What runs on it

| Zone | Services |
|------|----------|
| **DMZ** (public, behind SSO) | Authentik, Cloudflare Tunnel, Vaultwarden, Nextcloud, Immich, AFFiNE, Matrix (Synapse + Element + MAS + RTC), Seerr, KoalaSync, Ollama, SearXNG |
| **Private** (LAN) | Jellyfin (+ Moonfin client), Decypharr, Radarr, Sonarr, Bazarr, Prowlarr, qBittorrent, AIOStreams, Zilean, n8n, Gotify, Open WebUI, RustDesk, Hindsight, Docling, Firecrawl, FlareSolverr, MCP server, OpenClaw, Open-Terminal, NZBDav, PostgreSQL, Redis |
| **Monitoring** | Homepage, Uptime Kuma, Grafana, Loki, Promtail, Netdata |
| **Infra** | ArgoCD, Image Updater, cert-manager, Longhorn, MetalLB, Traefik, NetworkPolicies |

### Media: on-demand streaming, not a media library

The media stack works like a private streaming service — nothing is stored
locally until the moment someone presses play:

```
Seerr (requests) ─► Radarr/Sonarr ─► Decypharr ─► Real-Debrid ─► .strm files
                                                                      │
        Moonfin / Jellyfin ◄──────────── HTTP (on-demand) ◄───────────┘
```

- **~200 movies + 180 series** as lightweight `.strm` pointers; content
  resolves to a debrid-cached HTTPS stream at play time.
- **Decypharr** bridges the arr stack to the debrid service and keeps the
  `.strm` index in sync with the account.
- **Jellyfin 10.11** with the **Moonfin** client (custom Aurora Glass theme)
  and 34 plugins; a VPS nginx edge adds brotli, image/cache warmers, and
  auth-guarded row caches so cold opens are ~1–2 s.
- Quality/profile automation (scored custom formats), per-episode subtitles
  via Bazarr, and a weekly plugin-update check.

---

## Backups & disaster recovery

3-2-1 coverage, all automated, all verified with phone alerts:

| Layer | What | Schedule |
|-------|------|----------|
| **Snapshots** | Longhorn per-volume | daily 03:00, keep 5 |
| **Off-site** | Longhorn → NFS on VPS (WireGuard/NetBird transport) | daily 04:00, keep 7 |
| **On-site** | restic → local PC (SFTP) | daily 02:30, retry 08:00 |
| **Databases** | pg_dump all DBs | daily 02:00, keep 7 |
| **Config** | k3s state + app configs | daily 03:00 |
| **Integrity** | restic check | monthly |

**Failure alerting:** every leg pushes to Gotify on failure; a morning
watchdog script independently verifies freshness of all backup legs; a Kuma
push-monitor heartbeats the nightly chain. iOS delivery via iGotify.

The sanitized (credential-free) copies of all backup scripts live in
[`scripts/backup/`](scripts/backup/); the Longhorn target runbook is at
[`apps/infra/longhorn/BACKUP-TARGET.md`](apps/infra/longhorn/BACKUP-TARGET.md).

---

## How it works

### GitOps loop

The root application (`bootstrap/root-application.yaml`) discovers every child
`application.yaml` under `apps/`:

```yaml
directory:
  recurse: true
  include: "**/application.yaml"
```

Each service directory follows the same pattern:

- `application.yaml` — ArgoCD Application (chart + values ref + Image Updater annotations)
- `values.yaml` — Helm values (bjw-s `app-template`)

**Safety settings** — added after two early data-loss incidents:

```yaml
syncPolicy:
  automated:
    prune: false      # NEVER auto-prune — prevents namespace/PVC deletion
    selfHeal: false   # structural changes require a manual sync
```

> ⚠️ **Lesson learned:** ArgoCD syncs from the **committed** Git state, not
> the working tree. Uncommitted `values.yaml` edits are silently ignored —
> always commit and push before syncing.

### Secrets management

Credentials can't be committed to a public repo, but must survive cluster
rebuilds. **Sealed Secrets** solves this: secrets are encrypted with the
cluster's public key and committed as `SealedSecret`` resources (55 files
under `sealed-secrets/`). Only the cluster's private key — captured in
backups, never in this repo — can decrypt them.

```bash
kubeseal --format yaml < secret.yaml > sealed-secrets/<ns>/<name>.yaml
```

> This also means the sealed secrets in this repo are **useless to anyone
> who forks it** — by design. The [installer](installer/) generates your own
> from templates instead.

### Network security

1. **Physical segmentation** — 3 VLAN zones at the router.
2. **Default-deny in-cluster** — 40 NetworkPolicies; nothing talks to
   anything unless explicitly allowed.
3. **No exposed ports** — all public access via Cloudflare Tunnel.
4. **Single identity** — Authentik SSO with invite-only registration; LAN UIs
   sit behind basic auth.

### Automated updates

ArgoCD Image Updater watches annotated images, checks registries, and
commits version bumps back to this repo — 100+ automatic update commits so
far. The same loop updates Jellyfin plugins weekly with an E2E verifier.

---

## Self-hosting this repo

The stack is packaged for reuse:

```bash
./installer/install.sh
```

- Pick **any subset** of services (or a bundle: core / media / productivity / comms / ai / monitoring)
- The installer **generates your own sealed secrets** from templates (mine can't be reused — they're encrypted to my cluster)
- Rewires `mysweetpea.cc` → your domain across all values
- Applies only your selected apps and waits for them to go healthy

Requirements and full details: [`installer/README.md`](installer/).

---

## Repository layout

```
├── bootstrap/root-application.yaml   # App-of-apps root (prune:false)
├── installer/                        # Self-hosting installer + secret templates
│   ├── install.sh                    #   Interactive multi-service deployer
│   ├── services.yaml                 #   Service catalog (secrets needed per app)
│   └── secret-templates/             #   Placeholder secrets for kubeseal
├── apps/
│   ├── dmz/                          # Internet-facing (tunnel + SSO)
│   ├── private/                      # LAN services (media stack, DBs, AI tooling)
│   ├── monitoring/                   # Dashboards, status, logs, metrics
│   └── infra/                        # ArgoCD, Longhorn, MetalLB, netpols, ...
├── sealed-secrets/                   # 55 encrypted secrets (cluster-key bound)
├── scripts/
│   ├── backup/                       # Sanitized copies of the backup chain
│   └── customize-domain.sh           # Rewire domain for self-hosters
├── docs/                             # Architecture diagram, plugin state notes
└── workflows/                        # n8n workflow exports
```

---

## Common operations

```bash
# Sync an app
argocd app sync <app-name>

# Add a new service
#   1. apps/<ns>/<service>/{application.yaml,values.yaml}
#   2. commit + push  (ArgoCD reads committed state only)
#   3. kubectl apply -f apps/<ns>/<service>/application.yaml

# Seal a new secret
kubeseal --format yaml < secret.yaml > sealed-secrets/<ns>/<name>.yaml
```

---

## License / contact

The infrastructure code in this repo is provided as-is for reference and
self-hosting. Service containers carry their upstream licenses.

Questions: support@mysweetpea.cc
Infrastructure: https://github.com/mysweetpea/homelab-k8s · Website: https://github.com/mysweetpea/portfolio
