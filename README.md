# MySweetPea Homelab — Kubernetes GitOps

GitOps-managed 3-node K3s cluster running **40+ self-hosted services** for the
MySweetPea community. All infrastructure is declared as ArgoCD Applications in
this repo; secrets are committed only as **SealedSecrets** (encrypted with the
cluster's sealed-secrets key) — plaintext credentials never touch Git.

**Live site:** https://mysweetpea.cc
**Website repo:** https://github.com/mysweetpea/portfolio

---

## Architecture

- **3-node K3s cluster** (v1.36.1+k3s1, Ubuntu 26.04)
  - `k3s-master` (192.168.20.40) — control plane
  - `worker-a` (192.168.20.43)
  - `worker-b` (192.168.20.41)
- **Flannel** CNI, **Traefik** Ingress, **MetalLB** LoadBalancer (21-IP pool)
- **Longhorn** distributed storage (RWO + RWX) across all 3 nodes
- **Cloudflare Tunnel** for external access (no open inbound ports)
- **ArgoCD** GitOps + **Image Updater** (auto-update with git write-back) — 48 applications
- **Authentik** SSO (OIDC + LDAP + Proxy outposts) — 14+ public-facing services
- **Netbird** mesh VPN (host-level) for private LAN access + Oracle VPS relay
- **3-zone VLAN** segmentation (OpenWrt firewall) + **29 Kubernetes
  NetworkPolicies** enforcing default-deny ingress (17 dmz / 12 private)

---

## Repository layout

```
├── bootstrap/
│   └── root-application.yaml   # Root ArgoCD app (app-of-apps, prune:false)
├── apps/
│   ├── dmz/                    # Internet-facing services (behind tunnel/SSO)
│   │   ├── authentik/          # SSO provider (OIDC/LDAP/Proxy)
│   │   ├── authentik-ldap-outpost/
│   │   ├── authentik-tls-proxy/
│   │   ├── cloudflared/        # Cloudflare Tunnel
│   │   ├── element-web/        # Matrix client
│   │   ├── matrix-synapse/     # Matrix homeserver
│   │   ├── vaultwarden/        # Password manager
│   │   ├── affine/             # Notes
│   │   ├── seerr/              # Media requests
│   │   ├── koalasync/          # Sync
│   │   ├── ollama/             # Local LLM
│   │   ├── searxng/            # Private search
│   │   └── ingress-routes/     # Traefik IngressRoutes + Auth middleware
│   ├── private/                # LAN / internal services
│   │   ├── jellyfin/           # Media server (Moonfin + 34 plugins)
│   │   ├── postgresql/         # Shared PostgreSQL (PG18)
│   │   ├── n8n/                # Automation + webhook backend
│   │   ├── nextcloud/          # Files
│   │   ├── immich/ + immich-postgresql/  # Photos
│   │   ├── gotify/             # Notifications
│   │   ├── open-webui/         # AI chat
│   │   ├── radarr/ sonarr/ bazarr/ prowlarr/ qbittorrent/  # Media stack
│   │   ├── aiostreams/         # Streaming (Stremio-style)
│   │   ├── rustdesk/           # Remote desktop
│   │   ├── flaresolverr/       # Cloudflare-bypass proxy
│   │   ├── nzbdav/ openclaw/ mcp-server/ qdrant/ questarr/
│   │   ├── media-storage/      # Shared 200Gi media PVC
│   │   ├── redis-affine-master/
│   │   └── ingress-routes/
│   ├── monitoring/
│   │   ├── homepage/           # Dashboard (192.168.20.213)
│   │   ├── uptime-kuma/        # Status page (status.mysweetpea.cc)
│   │   ├── grafana/ + loki/ + promtail/ + netdata/   # Observability
│   │   └── ingress-routes/
│   └── infra/
│       ├── argocd/             # ArgoCD config
│       ├── argocd-image-updater/
│       ├── cert-manager/
│       ├── longhorn/
│       ├── metallb/
│       ├── network-policies/   # 29 NetworkPolicies (17 dmz + 12 private)
│       ├── coredns-custom.yaml
│       ├── traefik-dashboard.yaml
│       └── argocd-sync-windows.yaml
└── sealed-secrets/             # Encrypted secrets (28 files)
    ├── argocd/
    ├── dmz/
    └── private/
```

Each service directory follows the same pattern:

- `application.yaml` — ArgoCD Application (chart + values ref + Image Updater annotations)
- `values.yaml` — Helm values (bjw-s `app-template` chart)

---

## How GitOps works

The root app (`bootstrap/root-application.yaml`) discovers every child
`application.yaml` under `apps/` via:

```yaml
directory:
  recurse: true
  include: "**/application.yaml"
```

**Critical safety settings** (added after two data-loss incidents):

```yaml
syncPolicy:
  automated:
    prune: false      # NEVER auto-prune — prevents namespace/PVC deletion
    selfHeal: false   # requires manual sync for structural changes
```

The `private`, `dmz`, and `monitoring` namespaces carry
`helm.sh/resource-policy: keep` so they survive syncs.

> ⚠️ **Lesson:** ArgoCD syncs from the **committed** git state, not the working
> tree. Uncommitted `values.yaml` changes are silently ignored. Always commit +
> push before syncing.

---

## Secrets management

- **Plaintext secrets** live only on the cluster (`kubectl` secrets) and in the
  local (gitignored) `secrets/` directory — **never committed**.
- **SealedSecrets** (controller v0.38.4) are the repo's source of truth: 28
  encrypted secrets under `sealed-secrets/` (argocd / dmz / private), applied
  by ArgoCD and decryptable only with the cluster's sealed-secrets key.
- To seal a new secret:
  ```bash
  kubeseal --format yaml < secret.yaml > sealed-secrets/<ns>/<name>.yaml
  ```

---

## Common operations

### Sync an app
```bash
argocd login 192.168.20.220 --username admin --password <pass> --insecure
argocd app sync <app-name>
```

### Add a new service
1. Create `apps/<ns>/<service>/application.yaml` + `values.yaml`
2. Commit + push
3. `kubectl apply -f apps/<ns>/<service>/application.yaml`
4. `argocd app sync <service>`

### Auto-update
ArgoCD Image Updater watches annotated images and commits version bumps back to
this repo (git write-back via `argocd-image-updater-git-ssh`). Verify:
```bash
argocd-image-updater list
```

---

## External access

All public services are exposed through **Cloudflare Tunnel** (no inbound ports
open). Traefik routes by hostname; Authentik SSO protects member services.
The Oracle VPS (`relay`, 129.213.11.104) acts as a Netbird relay + nginx proxy
for media streaming.

The network is segmented into **3 VLAN zones** via the OpenWrt router firewall,
and every cluster namespace is isolated by default-deny NetworkPolicies.

---

## Backups

Automated backups run on `k3s-master` via cron:

| Script | Schedule | Purpose |
|--------|----------|---------|
| `pg-backup.sh` | daily 02:00 | PostgreSQL dumps → `/root/pg-dumps/` (4-day retention) |
| `config-backup.sh` | daily 03:00 | K8s configs → `/root/config-backup/` (7-day retention) |
| `restic-backup.sh` | daily 02:30 | restic → VPS (sftp 129.213.11.104) + PC (sftp 192.168.1.143); retention 7d/4w/6m + prune |

`restic-backup.sh` also captures the sealed-secrets key (critical for cluster
rebuild) and gzips the k3s state.db before upload (127 MB → ~11 MB).

---

## License / contact

Questions: support@mysweetpea.cc
Website: https://github.com/mysweetpea/portfolio
This repo: https://github.com/mysweetpea/homelab-k8s
