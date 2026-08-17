# Infra — Platform Components

This zone is the **foundation** the other zones run on: GitOps, networking,
storage, certificates, and security policies. These components are not
"services" users interact with — they are the platform itself.

## What's in here

| Component | What it does |
|-----------|--------------|
| `argocd/` | ArgoCD configuration — the GitOps engine that reconciles the cluster |
| `argocd-image-updater/` | Automated container image updates (see its [deep-dive](./argocd-image-updater/README.md)) |
| `cert-manager/` | Automatic TLS certificates for all ingress |
| `longhorn/` | Distributed block storage across all 3 nodes (RWO + RWX) |
| `metallb/` | Layer-2 load balancer (21-IP pool) for LoadBalancer services |
| `network-policies/` | Default-deny network security (see its [deep-dive](./network-policies/README.md)) |
| `coredns-custom.yaml` | Custom DNS entries for internal service names |
| `traefik-dashboard.yaml` | Traefik's admin dashboard |
| `argocd-sync-windows.yaml` | Scheduled sync windows for ArgoCD |

## Why these matter

- **ArgoCD** is the heart of the GitOps model — every application in `apps/`
  is declared here and reconciled continuously.
- **Longhorn** gives the cluster durable storage that survives node failures
  (replicas are spread across nodes).
- **MetalLB** provides stable IPs for LoadBalancer services on bare metal.
- **cert-manager** keeps TLS certificates valid automatically — no manual
  renewals.
- **network-policies** implement the zero-trust model described in the
  [main README](../../README.md).

## The safety settings

The root ArgoCD app uses `prune: false` and `selfHeal: false` — deliberate
choices made after two early data-loss incidents. The cluster never deletes
resources automatically; structural changes require an explicit sync.
