# Self-hosting installer

Deploy **any subset of the MySweetPea stack** to your own Kubernetes cluster.

The apps in this repo are plain ArgoCD Applications (app-of-apps). Four things
tie them to the original cluster:

1. **`repoURL`** — every Application reads its values from a git repo. Left
   as-is, ArgoCD pulls *the original author's* values and ignores your edits.
2. **Hardcoded domain** (`mysweetpea.cc`) in ingress routes and values.
3. **MetalLB load-balancer IPs** on the original LAN (`192.168.20.x`).
4. **Sealed secrets** that only the original cluster can decrypt.

The installer handles all four.

## What you get

| Bundle | Contents |
|--------|----------|
| `core` | ArgoCD + Image Updater, Longhorn, MetalLB, Traefik (k3s), cert-manager, NetworkPolicies, ingress routes |
| `monitoring` | Homepage dashboard, Uptime Kuma, Grafana + Loki + Promtail, Netdata |
| `media` | Jellyfin, Decypharr, Radarr/Sonarr/Bazarr/Prowlarr, qBittorrent, AIOStreams, Zilean, media PVC |
| `productivity` | Vaultwarden, Nextcloud, Immich (+ its PostgreSQL), AFFiNE (+ Redis), shared PostgreSQL |
| `comms` | Matrix Synapse + MAS + Element + RTC |
| `identity` | Authentik (+ outposts), Cloudflare Tunnel |
| `ai` | Ollama, Open WebUI, Hindsight, Docling, Firecrawl |

Bundles live in [`services.yaml`](services.yaml) — plain lists, easy to extend.
You can also pick individual services by name, or use `zone/name` for apps whose
basename appears in more than one zone.

## Requirements

- A Kubernetes cluster (K3s recommended — Traefik and MetalLB are wired for it)
- `kubectl` connected to it
- `helm` (for the `core` bundle: ArgoCD, cert-manager, Longhorn)
- `kubeseal` ([releases](https://github.com/bitnami-labs/sealed-secrets/releases))
- The [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) controller in the cluster
- `git` (the installer checks your fork is reachable)

## Quick start

```bash
# 1. Fork this repo on GitHub, then clone YOUR fork
git clone https://github.com/YOU/homelab-k8s.git
cd homelab-k8s

# 2. See exactly what would happen (changes nothing)
./installer/install.sh --dry-run

# 3. Run it
./installer/install.sh

# 4. Commit + push so ArgoCD can read the rewritten values
git add -A && git commit -m 'install: target my domain + fork' && git push
```

**Step 4 is not optional.** ArgoCD reads values from the *remote* repo, so
local-only commits are invisible to it.

### Non-interactive

```bash
DOMAIN=example.com BUNDLES=core,media FORK=https://github.com/YOU/homelab-k8s.git \
  ./installer/install.sh --yes
```

| Env var | Meaning |
|---|---|
| `DOMAIN` | your domain (default: keep `mysweetpea.cc`) |
| `BUNDLES` | comma-separated bundle names or numbers (`core,media` / `1,3`) |
| `SERVICES` | space-separated individual service names (option 9) |
| `FORK` | your fork URL (default: derived from `git remote get-url origin`) |
| `STRIP_LB` | `y` to strip hardcoded `192.168.20.x` loadBalancerIPs |
| `YES=1` | never prompt |

## What the installer does

1. **Preflight** — kubectl reachable, sealed-secrets controller found, and
   `kubeseal` verified against that controller *before* it is trusted
2. **Fork check** — rewrites every Application's `repoURL` (and the
   image-updater `git.repository`) to your fork; warns if it still points at
   upstream or if your local HEAD differs from the fork
3. **Domain + IPs** — optionally rewires the domain (validated, with a tarball
   backup first) and strips hardcoded MetalLB IPs
4. **Selection** — bundles, `everything`, or individual services
5. **Namespaces** — creates every namespace the selected Applications expect
6. **Deploy** — helm-installs the core components (ArgoCD, cert-manager,
   Longhorn), applies the k3s Traefik `HelmChart` CRs, and applies each
   Application; waits for ArgoCD's CRDs before applying Applications
7. **Secrets** — parses each app's `values.yaml` for `secretKeyRef` pairs plus
   the catalog, generates placeholders, seals them against *your* controller
8. **Summary** — lists placeholder secrets to replace and anything skipped

## What you'll need to fill in

Every generated secret carries `CHANGE_ME_*` placeholder values:

- `cloudflared-token` → your Cloudflare tunnel token
- `authentik-secret-key` → `openssl rand -base64 50`
- `*-postgresql` → your DB passwords
- `*-smtp` → SMTP credentials for outbound mail
- `decypharr-secrets` → your debrid provider API key
- `gotify` / `netdata-gotify` → notification tokens

To replace one:

```bash
kubectl -n <ns> delete secret <name>
# write a plain Secret manifest with real values, then:
kubeseal --controller-namespace <ss-ns> --controller-name sealed-secrets-controller \
  --format yaml < secret.yaml | kubectl apply -f -
```

## How secrets are derived

The installer does not keep a hand-written catalog. For each selected app it
parses that app's `values.yaml`, collects every `secretKeyRef.name` +
`secretKeyRef.key`, adds anything listed in `services.yaml`, and builds exactly
the secret the chart expects — so it stays correct as the repo evolves.

## Notes & limits

- **Deploy `core` first** on a fresh cluster — everything else is an ArgoCD
  Application and needs ArgoCD's CRDs.
- **Traefik** is applied as a k3s `HelmChart` CR (k3s reconciles it), not a helm
  CLI install. On non-K3s clusters, install Traefik yourself and skip that entry.
- **PVCs need a default StorageClass** (Longhorn is in `core`).
- **Media stack** expects a `/data/media` layout via the `media-storage` app and
  a debrid or usenet account for Decypharr.
- **Image auto-updates** write back to `git.repository` — the installer points
  that at your fork, so you need push access (a deploy key works).
- **LAN-only services** are reachable on their MetalLB IPs; public hostnames
  need the Cloudflare Tunnel (`identity`) plus your own DNS.
- **Sealed secrets are cluster-specific by design.** Yours cannot be reused by
  anyone else, and nobody else's can be reused by you.

## Support

The installer gives you a working skeleton — every service still needs its own
configuration (API keys, SMTP, upstream accounts). Issues welcome on GitHub.
