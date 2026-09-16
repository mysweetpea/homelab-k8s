<div align="center">

# 🌱 MySweetPea Homelab

**A production-grade, self-hosting platform on Kubernetes — with an installer anyone can run.**

[![installer CI](https://github.com/mysweetpea/homelab-k8s/actions/workflows/installer-lint.yml/badge.svg)](https://github.com/mysweetpea/homelab-k8s/actions/workflows/installer-lint.yml)
![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.36-326CE5?logo=kubernetes&logoColor=white)
![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-EF7B4D?logo=argo&logoColor=white)
![Apps](https://img.shields.io/badge/apps-56-8FAFB5)
![Tests](https://img.shields.io/badge/tests-126%20passing-3FB68B)

**56 services · 2 install methods · 3 commands from bare metal to a working homelab**

[Get Started](#-get-started) · [What's Inside](#-whats-inside) · [How It Works](#-how-it-works) · [For Employers](#-for-employers)

</div>

---

## Why this exists

Most self-hosted setups demand you learn Kubernetes, Helm, and YAML before you get anything useful.
This repo inverts that: **the platform is the product, and the installer is the front door.**

Answer questions like *"I want a private photo vault"* or *"stream my movies anywhere"* — the installer
resolves what to deploy, in what order, with what dependencies, and hands you working URLs at the end.

> Non-technical? Follow [docs/01-getting-started.md](docs/01-getting-started.md) — no Kubernetes
> knowledge needed, ever.
>
> Already run a cluster? Skip straight to [installer/README.md](installer/README.md).

---

## 🚀 Get started

### Path A — one Linux box, zero experience

```bash
# on the target machine (Ubuntu/Debian, 8GB+ RAM):
curl -fsSL https://raw.githubusercontent.com/mysweetpea/homelab-k8s/main/installer/provision-k3s.sh | bash

git clone https://github.com/mysweetpea/homelab-k8s.git && cd homelab-k8s
./installer/wizard.sh     # pick what you want, in plain language
./installer/deploy.sh --plan homelab-plan.env
```

### Path B — you already run Kubernetes

```bash
git clone https://github.com/mysweetpea/homelab-k8s.git && cd homelab-k8s
./installer/wizard.sh
./installer/deploy.sh --plan homelab-plan.env
```

When it finishes you get a table of your services' URLs, and a permanent `homelab` command
(`homelab status` · `homelab urls` · `homelab open <app>`) to live with them.

---

## 📦 What's inside

56 ArgoCD-managed services across five zones. Highlights:

| Zone | Services |
|---|---|
| 🎬 **Media** | Jellyfin · Seerr (family requests) · Radarr/Sonarr/Prowlarr/Bazarr · Decypharr |
| 🔐 **Private cloud** | Vaultwarden · Nextcloud · Immich · AFFiNE · n8n |
| 💬 **Comms** | Matrix (Synapse + MAS + Element) · Element Call (voice/video) |
| 🤖 **AI** | Ollama · Open WebUI · Hindsight · Docling · Firecrawl |
| 🖥️ **Platform** | Authentik SSO · ArgoCD · Longhorn · MetalLB · Traefik · Grafana/Loki · Uptime Kuma |

<details>
<summary><strong>Full service catalog (expand)</strong></summary>

Use-case → what you get (the wizard's language):

*Photos* → Immich · *Files & notes* → Nextcloud + AFFiNE · *Passwords* → Vaultwarden ·
*Media server* → Jellyfin · *Automated downloads* → the *arr stack · *Watch together* → KoalaSync ·
*Chat & calls* → Matrix + Element Call · *Local AI chat* → Ollama + Open WebUI · *AI tools* →
Docling + Firecrawl · *Dashboard* → Homepage · *Monitoring* → Uptime Kuma + Grafana + Loki +
Netdata · *Automation* → n8n · *Family requests* → Seerr · *Private search* → SearXNG ·
*Notifications* → Gotify (+ iPhone relay)

</details>

---

## ⚙️ How it works

Two install methods — chosen in the wizard, both fully supported:

| | **Appliance** (default) | **GitOps** |
|---|---|---|
| Needs a GitHub account | ❌ No | ✅ Yes |
| How your choices are applied | Inline overrides rendered onto each app | Your own fork, auto-created & pushed via `gh` |
| App auto-updates | In-cluster write-back | Commits to your fork |
| Best for | Simplest possible start | Remote backup + full change history |

Under both: **ArgoCD** keeps the cluster reconciled to the desired state, **sealed-secrets** means
no plaintext secret ever touches disk or git, **Longhorn** replicates your data, and **Authentik**
gives every service one login.

<div align="center">

`provision` → `wizard` → `deploy` → `homelab status` — that's the whole journey.

</div>

---

## 🧭 Documentation

| Doc | For |
|---|---|
| [docs/01-getting-started.md](docs/01-getting-started.md) | First-timers: hardware, install day, first login |
| [docs/02-architecture.md](docs/02-architecture.md) | How the platform fits together (with diagrams) |
| [docs/03-security-model.md](docs/03-security-model.md) | SSO, secrets, network policy, backups |
| [docs/04-day-2-operations.md](docs/04-day-2-operations.md) | Adding/removing apps, updates, monitoring, recovery |
| [docs/05-troubleshooting.md](docs/05-troubleshooting.md) | Common failures and exact fixes |
| [installer/README.md](installer/README.md) | Installer internals: wizard, methods, engines, tests |

---

## 💼 For employers

This repository is a working demonstration of production platform engineering, not a tutorial:

- **GitOps at scale** — 56 ArgoCD Applications with automated drift correction and image
  automation; the cluster is the source of truth and self-heals.
- **Real installer engineering** — a 3,000-line bash product with a TUI wizard, dependency
  resolution, two deployment engines, idempotent re-runs, and **126 passing tests** across
  7 suites, guarded by CI (syntax + CRLF portability + full suite + ephemeral-cluster e2e).
- **Security by default** — SSO on every public service, sealed-secrets (no plaintext secrets
  anywhere), network policies between zones, automated encrypted offsite backups (3-2-1).
- **Cross-platform discipline** — portability landmines (CRLF, Windows path handling) found,
  fixed, and locked behind CI so they cannot regress.
- **Operated for real** — this stack has run continuously for a real user community since 2025,
  with monitoring, alerting-to-phone, and documented incident history.

<details>
<summary><strong>Skills demonstrated (expand)</strong></summary>

Kubernetes (k3s) · ArgoCD GitOps · Helm · sealed-secrets · Longhorn storage · MetalLB ·
Traefik · Authentik OIDC/LDAP · PostgreSQL · Cloudflare Tunnel · bash product engineering ·
test design · CI/CD · GitHub Actions · observability (Grafana/Loki/Netdata/Uptime Kuma) ·
backup & disaster recovery · security hardening

</details>

---

## 📊 Status

- **CI:** lint + tests + e2e run on every `installer/**` change
- **Self-updating:** apps track upstream releases automatically (semver), then ArgoCD rolls them out
- **Backups:** nightly, verified, alerting on failure (see [docs/04](docs/04-day-2-operations.md))

---

<div align="center">
<sub>Built and operated by <a href="https://github.com/mysweetpea">@mysweetpea</a> ·
licensed under the <a href="LICENSE">MIT License</a></sub>
</div>
