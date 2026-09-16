# 01 — Getting started (zero experience required)

This guide assumes you have never used Kubernetes. That's fine — the installer handles it.

---

## What you need

| Thing | Minimum | Notes |
|---|---|---|
| A computer running Ubuntu/Debian Linux | 4 CPU cores, 8 GB RAM, 100 GB disk | An old laptop or a mini-PC is perfect. VirtualBox/Proxmox VM also works. |
| Internet connection | any | Downloads ~2 GB during install |
| 30 minutes | | Mostly waiting |

> Windows or macOS only? Run Ubuntu in a virtual machine
> ([VirtualBox](https://www.virtualbox.org/) is free) and continue below inside that VM.

---

## Install day, step by step

### 1. Put Linux on the machine

Already have Ubuntu/Debian on it? Skip ahead. Otherwise install Ubuntu Server — accept the
defaults; the only question that matters is creating your user account.

### 2. Copy/paste this (one line)

```bash
curl -fsSL https://raw.githubusercontent.com/mysweetpea/homelab-k8s/main/installer/provision-k3s.sh | bash
```

What just happened: your machine became a Kubernetes node. The script checks your hardware,
installs Kubernetes (a lightweight flavor called k3s), waits until it's healthy, and — if you gave
it `--with-metallb-range <ip-range>` — gives your future apps real IPs on your home network.

### 3. Get this repository onto the machine

```bash
git clone https://github.com/mysweetpea/homelab-k8s.git
cd homelab-k8s
```

### 4. The wizard

```bash
./installer/wizard.sh
```

It asks, in plain English:

1. **What do you want?** — check off things like "Passwords", "Photos", "Media server".
   Descriptions are written for humans; dependencies are handled for you.
2. **Where can the internet reach it?** — "home network only" (private) or "my own domain"
   (from anywhere; needs a Cloudflare account).
3. **One login for everything?** — recommended: yes. You get a single sign-on page for all apps.
4. **Where should your settings live?** — "on this machine" (simplest) or "GitHub" (free off-site
   backup of your configuration; needs a free GitHub account).
5. A **plain-language summary** with a memory estimate. Confirm.

Passwords and keys are generated *for you* and saved into `homelab-credentials.txt` — move that
file somewhere safe (a password manager is ideal) and delete it from the machine afterward.

### 5. Deploy

```bash
./installer/deploy.sh --plan homelab-plan.env
```

Downloads, seals secrets, and starts everything. First run takes 15–40 minutes depending on what
you picked and your internet speed. It is safe to re-run if interrupted.

### 6. Live in it

```bash
./homelab status     # is everything healthy?
./homelab urls       # your addresses
./homelab open vaultwarden
```

Sign in at any app's address with the account from step 4's single-login question. Welcome to
your own private internet.

---

## If something goes wrong

- **Re-run the last command.** Everything is idempotent — safe to repeat.
- **`./homelab status` is your compass.** Anything `Degraded`?
  See [05-troubleshooting.md](05-troubleshooting.md).
- Worst case: [04-day-2-operations.md](04-day-2-operations.md) covers full disaster recovery from
  backups.
