# DMZ — Internet-Facing Services

This zone holds services that are reachable from the internet. They are
protected by three layers: a **Cloudflare Tunnel** (no inbound ports open),
**Authentik SSO** (single sign-on, invite-only registration), and
**default-deny NetworkPolicies** (nothing can talk to anything without an
explicit rule).

## Why a DMZ?

Services that must be reachable from the internet are the highest-risk part of
any network. Keeping them in their own zone means:

- A compromise in one service is **contained** — it cannot reach the private
  zone (no policy allows it).
- The attack surface is **minimal** — no open ports, no direct IP access, only
  the tunnel.
- Access is **identity-based** — every user authenticates through Authentik
  before reaching anything.

## What's in here

| Service | What it does |
|---------|--------------|
| `authentik/` | SSO provider (OIDC/OAuth2 + LDAP + Proxy outposts) — one account for everything |
| `authentik-ldap-outpost/` | LDAP bridge for services that speak LDAP instead of OIDC |
| `authentik-tls-proxy/` | TLS-terminating proxy for SSO-protected services |
| `cloudflared/` | Cloudflare Tunnel — the only way in from the internet |
| `matrix-synapse/` | Matrix homeserver (federated chat) |
| `element-web/` | Matrix web client |
| `vaultwarden/` | Password manager (Bitwarden-compatible) |
| `affine/` | Notes / knowledge base |
| `seerr/` | Media request portal (Jellyfin integration) |
| `koalasync/` | File sync |
| `ollama/` | Local LLM inference |
| `searxng/` | Private, self-hosted search |
| `ingress-routes/` | Traefik IngressRoutes + auth middleware wiring |

## How access works

```
Internet → Cloudflare Tunnel → Traefik → Authentik SSO → Service
```

Every request is authenticated at the edge of the cluster. No service in this
zone manages its own user database — identity lives in Authentik.
