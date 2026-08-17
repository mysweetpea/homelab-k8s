# NetworkPolicies — Zero-Trust Network Security

This folder is the enforcement point of the cluster's security model:
**default-deny everywhere, allow only what's explicitly needed.**

## The problem

Kubernetes by default allows **any pod to talk to any other pod**. In a
cluster running 40+ services — including internet-facing ones — that's
unacceptable. A single compromised service could reach the database, the
password manager, everything.

## The solution

29 NetworkPolicies (17 in `dmz`, 12 in `private`) implement a zero-trust model:

- **Default-deny** — every namespace starts with a policy that blocks all
  ingress (and egress where it matters). Nothing is reachable unless a policy
  explicitly allows it.
- **Least privilege** — policies allow only the specific pod-to-pod or
  pod-to-namespace flows that services actually need.

## What the policies look like

The file is generated from live cluster state and contains policies like:

| Policy | What it allows |
|--------|----------------|
| `default-deny` | Blocks all ingress to the namespace (the baseline) |
| `allow-ingress-controller` | Lets Traefik (in `kube-system`) reach service pods |
| `allow-dns-egress` | Lets pods reach CoreDNS (port 53) |
| `allow-internet-egress` | Lets specific pods reach the internet (egress) |
| `allow-authentik-postgresql-ingress` | Lets Authentik reach its database (port 5432) |
| `allow-seerr-arr-ingress` | Lets Seerr talk to Radarr/Sonarr |
| `allow-jellyfin-ldap-outpost-ingress` | Lets the LDAP outpost reach Jellyfin |
| `allow-lan-vpn-ingress` | Lets LAN/VPN clients reach specific services |

Each policy is scoped with `podSelector` (which pods) + `from`/`to`
(which sources/destinations) + `ports` (which ports). Example:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-authentik-postgresql-ingress
  namespace: dmz
spec:
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app.kubernetes.io/instance: authentik
    ports:
    - port: 5432
      protocol: TCP
  podSelector:
    matchLabels:
      app.kubernetes.io/component: primary
      app.kubernetes.io/instance: authentik
      app.kubernetes.io/name: postgresql
  policyTypes:
  - Ingress
```

## How this fits the bigger picture

NetworkPolicies are one layer of a defense-in-depth model:

1. **Physical** — 3-zone VLAN segmentation at the router (OpenWrt firewall)
2. **Cluster** — these default-deny NetworkPolicies
3. **Edge** — Cloudflare Tunnel, no inbound ports
4. **Identity** — Authentik SSO on every public service

## Operations

- Policies are applied by ArgoCD like any other manifest.
- To add a policy: append to `network-policies.yaml`, commit, push, sync.
- To verify the live state: `kubectl get networkpolicies -A`
