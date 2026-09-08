# Self-hosting installer

Deploy **any subset of the MySweetPea stack** to your own Kubernetes cluster.

The apps in this repo are plain ArgoCD Applications (app-of-apps). The only
things that tie them to the original cluster are (a) the domain hardcoded in
ingress routes and values, (b) MetalLB load-balancer IPs on the original LAN,
and (c) sealed secrets that only the original cluster can decrypt. This
installer handles all three.

## What you get

| Bundle | Contents |
|--------|----------|
| `core` | ArgoCD + Image Updater, Longhorn, MetalLB, Traefik, NetworkPolicies, ingress routes |
| `monitoring` | Homepage dashboard, Uptime Kuma, Grafana + Loki + Promtail, Netdata |
| `media` | Jellyfin, Decypharr, Radarr/Sonarr/Bazarr/Prowlarr, qBittorrent, AIOStreams, Zilean, media PVC |
| `productivity` | Vaultwarden, Nextcloud, Immich (+ its PostgreSQL), AFFiNE (+ Redis), shared PostgreSQL |
| `comms` | Matrix Synapse + MAS + Element + RTC |
| `identity` | Authentik (+ outposts), Cloudflare Tunnel |
| `ai` | Ollama, Open WebUI, Hindsight, Docling, Firecrawl |

Bundles are defined in [`services.yaml`](services.yaml) — plain lists, easy to
extend. The installer also supports picking individual services by name.

## Requirements

- A Kubernetes cluster (K3s recommended; any cluster with the
  [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets) controller works)
- `kubectl` connected to it
- `kubeseal` ([releases](https://github.com/bitnami-labs/sealed-secrets/releases))
- Optional: a Cloudflare tunnel token if you pick `identity`

## Quick start

```bash
git clone https://github.com/mysweetpea/homelab-k8s.git
cd homelab-k8s
./installer/install.sh
```

The installer will:

1. **Verify preflight** — cluster reachable, sealed-secrets controller found
2. **Ask for your domain** — rewrites `mysweetpea.cc` across all values and
   routes (in your local clone; it will warn you not to push that upstream)
3. **Offer to strip hardcoded MetalLB IPs** so they auto-assign on your LAN
4. **Let you pick bundles or services**
5. **Generate secrets** — reads each app's `values.yaml`, finds every
   `secretKeyRef`, creates a sealed placeholder secret with random
   `CHANGE_ME_*` values (the original cluster's sealed secrets can't be
   reused — they're encrypted to its key by design)
6. **Apply the ArgoCD Applications** for exactly your selection

At the end it prints the list of placeholder secrets you must replace with
real credentials (API keys, SMTP, DB passwords — service-specific).

## What you'll need to fill in

Every generated secret carries `CHANGE_ME_*` placeholder values. Typical
examples:

- `cloudflared-token` → your Cloudflare tunnel token
- `authentik-secret-key` → `openssl rand -base64 50`
- `*-postgresql` → your DB passwords
- `*-smtp` → SMTP credentials for outbound mail
- `decypharr-secrets` → your debrid provider API key
- `gotify`/`netdata-gotify` → notification tokens

Replace a placeholder:

```bash
kubectl -n <ns> delete secret <name>
# edit a plain Secret manifest with real values, then:
kubeseal --controller-namespace <ss-ns> --format yaml < secret.yaml \
  | kubectl apply -f -
```

## How secrets are derived

The installer never maintains a hand-written catalog. For each selected app
it parses that app's `values.yaml`, collects every `secretKeyRef.name` +
`secretKeyRef.key`, and builds exactly the secret the chart expects — so it
stays correct even as the repo evolves.

## Notes & limits

- **ArgoCD first**: on a fresh cluster deploy `core` before anything else —
  everything else is an ArgoCD Application.
- **The root app-of-apps** (`bootstrap/root-application.yaml`) deploys
  *everything*; the installer instead applies individual Applications so you
  get only your selection. Both approaches work; the installer's is for
  subsets.
- **PVCs need a default StorageClass** (Longhorn recommended — it's in `core`).
- **Media stack** expects `/data/media` layout via the `media-storage` app
  (Longhorn RWX PVC) and a debrid account for Decypharr.
- **Image auto-updates** use git write-back to *this* repo — for your fork,
  either disable the image-updater app or point it at your fork.
- LAN-only services (Radarr, Jellyfin, …) are reachable via their MetalLB
  IPs; public hostnames require the Cloudflare Tunnel (`identity` bundle) and
  DNS setup on your side.

## Support

This installer provides a working skeleton — every service still needs its
own configuration (API keys, SMTP, upstream accounts) via the placeholder
secrets. Questions: support@mysweetpea.cc
