# 03 — Security model

Defense in depth: identity at the edge, secrets never in plaintext, workloads isolated, data
backed up and verifiable.

## Identity — one login (Authentik)

- Every internet-exposed app authenticates through **Authentik** (OIDC where native,
  Traefik **forward-auth** middleware otherwise, LDAP outpost for devices).
- Optional MFA (TOTP/WebAuthn), login-failed and admin-login alerting to your phone.
- Signups disabled per-app; account creation is an explicit admin action.

## Secrets — sealed, never plaintext

- The wizard **generates** strong random secrets; `kubeseal` encrypts them into
  `SealedSecret` objects that are safe to store in git. Only the cluster can decrypt.
- The controller key is the crown jewel: the installer prints its backup location and
  [04-day-2-operations.md](04-day-2-operations.md) covers restoring it (without it, sealed
  secrets cannot be re-decrypted on a rebuilt cluster).
- Guided mode writes generated credentials to `homelab-credentials.txt` — **move it into your
  password manager and delete the file**.

## Network — zones and least exposure

- Kubernetes **NetworkPolicies** partition dmz / private / monitoring; pods only talk along
  declared paths.
- Public exposure is by choice: **LAN-only** (default) or **Cloudflare Tunnel** — no router
  port-forwarding, origin IP hidden, and the tunnel token lives in a sealed secret.
- LAN-facing load balancer IPs are RFC1918; nothing is exposed unless you asked for it.

## Data — replicated, backed up, verified

- **Longhorn** replicates every volume (2 replicas by default) and snapshots nightly.
- Nightly **restic** backups of configs and databases to an off-site target, with automatic
  failure alerting (phone push) — a backup you haven't tested is a wish, so the chain is
  monitored end to end.
- Database dumps on a schedule for every stateful app.

## Supply chain

- All images pinned by tag with **semver auto-updates**; rollouts go through ArgoCD (rollback =
  `git revert` in GitOps mode, CR patch in appliance mode).
- CI runs the full test suite plus an ephemeral end-to-end cluster on every installer change.
- No plaintext secret has ever been committed; a scanner runs in CI to keep it that way.

## Reporting

Found something? Open an issue marked `security` — or use the contact in the repository owner's
profile. Please don't open a public PR that exposes the vulnerability detail.
