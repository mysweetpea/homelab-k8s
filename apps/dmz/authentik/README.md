# Authentik — Single Sign-On (SSO)

Authentik is the **identity layer** of the cluster: one account, one password,
every service. It provides OIDC/OAuth2, LDAP, and reverse-proxy authentication
to 14+ public-facing services.

## Why SSO?

Before Authentik, every service had its own user database and password. That
meant:

- Users had to remember N passwords (and reuse them).
- Every service was a separate attack surface for credential theft.
- There was no central place to revoke access.

With Authentik:

- **One identity** — users sign in once and are authenticated everywhere.
- **Central control** — accounts, groups, and access can be managed in one
  place; revoking one account cuts off everything.
- **Invite-only registration** — new accounts are created via invite codes,
  so the community stays closed and auditable.
- **Standard protocols** — OIDC/OAuth2 for modern apps, LDAP for legacy ones,
  and a reverse-proxy outpost for apps with no auth of their own.

## Components

| Component | Role |
|-----------|------|
| `authentik/` | The core server (web UI, API, worker) + its PostgreSQL database |
| `authentik-ldap-outpost/` | LDAP bridge for services that speak LDAP (e.g. Jellyfin) |
| `authentik-tls-proxy/` | Reverse-proxy outpost that enforces auth at the edge for proxied apps |

## How access flows

```
User → Cloudflare Tunnel → Traefik → Authentik (login) → Service
                                    │
                                    └─ OIDC token / LDAP bind / proxy session
```

For OIDC apps, the service redirects to Authentik's login page and receives a
token. For proxied apps, the outpost intercepts the request and injects the
authenticated identity. For LDAP apps, the outpost answers bind queries
against Authentik's user store.

## Security notes

- Registration is **invite-only** — no open signups.
- The Authentik database is isolated by NetworkPolicy (only Authentik pods
  can reach it, port 5432).
- Secrets (secret key, DB password) are stored as SealedSecrets — never
  plaintext in Git.
- Blueprints are managed declaratively (see `blueprints/`) so the SSO
  configuration is reproducible from this repo.
