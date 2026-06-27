# MySweetPea Homelab — Kubernetes GitOps

K3s cluster managed by ArgoCD. All secrets are stored locally and never committed.

## Architecture
- 3-node K3s cluster (v1.36.1+k3s1)
- Flannel CNI, Traefik Ingress, MetalLB LoadBalancer
- Longhorn distributed storage
- Cloudflare Tunnel for external access
- ArgoCD GitOps + Image Updater

## Structure
- `apps/` — Application manifests (committed)
- `bootstrap/` — Root ArgoCD application
- `secrets/` — Local-only secrets (never committed, .gitignore'd)
