# MySweetPea Homelab — Kubernetes GitOps

GitOps-managed K3s cluster running the MySweetPea self-hosted service stack.
All infrastructure is declared as ArgoCD Applications in this repo; secrets are
**never committed** (plaintext secrets live only on the cluster / local disk,
encrypted backups are committed as SealedSecrets).

**Live site:** https://mysweetpea.cc
**Website repo:** https://github.com/mysweetpea/portfolio

---

## Architecture

- **3-node K3s cluster** (v1.36.1+k3s1)
  - `k3s-master` (192.168.20.40)
  - `worker-a` (192.168.20.43)
  - `worker-b` (192.168.20.41)
- **Flannel** CNI, **Traefik** Ingress, **MetalLB** LoadBalancer
- **Longhorn** distributed storage (RWX via NFS)
- **Cloudflare Tunnel** for external access (no open inbound ports)
- **ArgoCD** GitOps + **Image Updater** (auto-update with git write-back)
- **Authentik** SSO (OIDC + LDAP + Proxy outposts)
- **Netbird** VPN for private LAN access + Oracle VPS relay

---

## Repository layout

```
├── bootstrap/
│   └── root-application.yaml   # Root ArgoCD app (app-of-apps, prune:false)
├── apps/
│   ├── dmz/                    # Internet-facing services (behind tunnel/SSO)
│   │   ├── authentik/          # SSO provider
│   │   ├── authentik-ldap-outpost/
│   │   ├── authentik-tls-proxy/
│   │   ├── cloudflared/        # Cloudflare Tunnel
│   │   ├── element-web/        # Matrix client
│   │   ├── matrix-synapse/     # Matrix homeserver
│   │   ├── jellyfin/           # Media server
│   │   ├── vaultwarden/        # Password manager
│   │   ├── affine/             # Notes
│   │   ├── seerr/              # Media requests
│   │   ├── koalasync/          # Sync
│   │   ├── ollama/             # Local LLM
│   │   ├── searxng/            # Private search
│   │   └── ingress-routes/     # Traefik IngressRoutes + Auth middleware
│   ├── private/                # LAN / internal services
│   │   ├── postgresql/         # Shared PostgreSQL (PG18)
│   │   ├── n8n/                # Automation + webhook backend
│   │   ├── nextcloud/          # Files
│   │   ├── immich/             # Photos
│   │   ├── gotify/             # Notifications
│   │   ├── open-webui/         # AI chat
│   │   ├── radarr/ sonarr/ bazarr/ prowlarr/ qbittorrent/  # Media stack
│   │   ├── aiostreams/         # Streaming
│   │   ├── rustdesk/           # Remote desktop
│   │   ├── nzbdav/ openclaw/ mcp-server/ qdrant/ questarr/
│   │   └── ingress-routes/
│   ├── monitoring/
│   │   ├── homepage/           # Dashboard (192.168.20.213)
│   │   ├── uptime-kuma/        # Status page (status.mysweetpea.cc)
│   │   ├── netdata/            # Metrics
│   │   └── ingress-routes/
│   └── infra/
│       ├── argocd-image-updater/
│       ├── cert-manager/
│       ├── metallb/
│       ├── network-policies/   # 16 NetworkPolicies (dmz + private)
│       ├── coredns-custom.yaml
│       └── argocd-sync-windows.yaml
└── sealed-secrets/
    ├── argocd/                 # Encrypted backups (committed)
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
  local `secrets/` directory — **never committed** (see `.gitignore`).
- **SealedSecrets** (controller v0.38.4) are committed under `sealed-secrets/`
  as encrypted backups for cluster rebuild.
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

---

## Backups

Local automated backups run on `k3s-master` via cron:

| Script | Schedule | Purpose |
|--------|----------|---------|
| `pg-backup.sh` | daily 02:00 | PostgreSQL dumps → `/root/pg-dumps/` (7-day retention) |
| `config-backup.sh` | daily 03:00 | K8s configs → `/root/config-backup/` (7-day retention) |
| `rsync-to-pc.sh` | weekly Sun 04:00 | Offsite sync (needs PC_IP/PC_USER/PC_PATH configured) |

---

## License / contact

Questions: support@mysweetpea.cc
Website: https://github.com/mysweetpea/portfolio
This repo: https://github.com/mysweetpea/homelab-k8s
# pat push test
