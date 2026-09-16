# MySweetPea Homelab — self-hosting, the easy way

[![installer CI](https://github.com/mysweetpea/homelab-k8s/actions/workflows/installer-lint.yml/badge.svg)](https://github.com/mysweetpea/homelab-k8s/actions/workflows/installer-lint.yml)
[![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.36.1-326CE5?logo=kubernetes&logoColor=white)](https://k3s.io)
[![Apps](https://img.shields.io/badge/Apps-54-8FAFB5)](#whats-inside)

A complete GitOps homelab: **pick what you want from plain-language choices, and the installer builds it** — media server, photo vault, password manager, private AI chat, and 50 more services on a lightweight Kubernetes cluster.

No YAML editing. No memorizing helm commands. The wizard asks what you want in plain English.

---

## Quick start

### You have a fresh Linux box (recommended)

```bash
# 1. provision the cluster (on the box)
curl -fsSL https://raw.githubusercontent.com/mysweetpea/homelab-k8s/main/installer/provision-k3s.sh | bash

# 2. grab the repo + start the wizard (on your laptop)
git clone https://github.com/mysweetpea/homelab-k8s && cd homelab-k8s
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config   # or scp from the box
./installer/wizard.sh
```

### You already have a k3s cluster

```bash
git clone https://github.com/mysweetpea/homelab-k8s && cd homelab-k8s
./installer/wizard.sh
```

### You just want everything, no questions

```bash
./installer/install.sh              # the classic full installer
```

---

## What the wizard asks

| Step | Question | Example answer |
|---|---|---|
| 1 | **What do you want?** | ☑ Photos ☑ Passwords ☑ Media server |
| 2 | **How private?** | LAN-only · my own domain |
| 3 | **One login for everything?** | yes → single sign-on wired in |
| 4 | **Where do settings live?** | On this machine · my GitHub |
| 5 | **Review** | app list + RAM estimate → confirm |

Then it deploys. Guided mode auto-generates strong passwords and saves them to `homelab-credentials.txt`.

## Two installation methods

| | **On this machine** (appliance) | **My GitHub** (GitOps) |
|---|---|---|
| Needs a GitHub account | **No** | Yes |
| Auto-updates | yes (in-cluster) | yes (via your fork) |
| Remote backup of your setup | no | yes |
| Best for | simplest start | customization + DR |

Both methods: dependency resolution (photos → Immich → its database), secret sealing, and sane deploy order are automatic.

## After install

```bash
./homelab status              # what's running
./homelab urls                # your service addresses
./homelab open jellyfin       # one URL
```

## What's inside

- **54 apps** across media, productivity, AI, monitoring, comms, identity — every one with a plain-language description and RAM estimate in [`installer/services.yaml`](installer/services.yaml)
- **k3s** + ArgoCD (self-healing GitOps) · **Longhorn** (replicated storage) · **MetalLB** (real LAN IPs) · **Traefik** (ingress)
- **Sealed secrets** — no plaintext credentials in cluster manifests
- **Auto-updates** — argocd-image-updater watches upstream for new versions

## Requirements

- Linux box with 4GB+ RAM (8GB recommended for media + photos)
- `bash`, `git`, `kubectl` connected to your cluster
- GitHub mode only: [`gh` CLI](https://cli.github.com/) (the wizard offers to install missing tools)

## Documentation

- Install options & secrets model: [`installer/README.md`](installer/README.md)
- App catalog: [`installer/services.yaml`](installer/services.yaml)
- Design notes: [`docs/`](docs/)

## Status

- **126 automated assertions** across 7 test suites, run in CI on every push to `installer/**`
- Portability-guarded: every script LF-enforced and syntax-checked (CRLF line endings kill Linux bash instantly — Windows editors introduce them silently)
- Proven end-to-end on a real cluster; the appliance renderer is validated against all 56 Application manifests

