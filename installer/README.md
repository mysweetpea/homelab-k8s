# The Installer

A dependency-free bash product that turns "I want a private photo vault" into a running,
monitored deployment — on your cluster, your terms.

```
provision-k3s.sh ─▶ wizard.sh ─▶ deploy.sh ─▶ homelab-manage.sh
   (fresh box)      (choose)      (apply)       (live with it)
```

## Components

| File | Role |
|---|---|
| `provision-k3s.sh` | Fresh Linux box → healthy k3s node (+ optional MetalLB pool). Idempotent. |
| `wizard.sh` | Guided flow: use-cases → app grid → exposure → SSO → method → review. Writes `homelab-plan.env`. `MSP_MODE=expert` for the full grid. |
| `deploy.sh --plan <file>` | Executes the plan: GitOps handoff (`gh` fork+push) **or** appliance render+apply. Generates and seals secrets (guided mode: automatic). |
| `homelab-manage.sh` | Left on the machine: `status` / `urls` / `open <app>`. |
| `install.sh` | The classic engine (bundles/individual services, domain + LB rewrites, sealed secrets) — still what `deploy.sh` drives in GitOps mode. |
| `services.yaml` | The catalog: 54 apps × {description, ram, dependencies, use-cases, subdomain, secrets}. |
| `lib/` | `ui.sh` (TUI ladder) · `catalog.sh` (loading, dep closure, validation) · `github.sh` (device-flow, fork, push, sync) · `appliance.sh` (no-GitHub renderer). |
| `test/` | 7 suites, 126 assertions, all offline. |

## Two deployment methods

**Appliance** (no GitHub account):
`$values` source re-pointed upstream · choices injected as `helm.valuesObject` (top ArgoCD
precedence) · image-updater write-back flipped `git → argocd` (updates patch the Application CR
in-cluster). Nothing to maintain outside the machine.

**GitOps** (recommended once you want off-site config backup):
GitHub device-flow auth → idempotent fork → repoURL rewrite → commit+push → ArgoCD reconciles
from *your* repo. Upstream updates merge on demand (`gh_sync_upstream`).

## Environment variables (skip the prompts)

| Var | Used by | Meaning |
|---|---|---|
| `MSP_UI` | wizard | `plain` / `ansi` / `fzf` / `whiptail` (auto-detected by default) |
| `MSP_MODE` | wizard | `guided` (default) / `expert` |
| `MSP_PLAN_FILE` | wizard/deploy | plan path (default `homelab-plan.env`) |
| `MSP_EXPOSURE` | wizard | `lan` / `domain` |
| `MSP_SSO` | wizard | `yes` / `no` |
| `MSP_METHOD` | wizard | `appliance` / `github` |
| `MSP_DOMAIN_OVERRIDE` | appliance renderer | domain substituted into overrides |
| `SERVICES` / `BUNDLES` / `FORK` / `DOMAIN` / `YES` | install.sh | classic engine inputs |

## Testing

```bash
for t in catalog ui wizard github appliance provision deploy; do
  bash installer/test/test-$t.sh
done
```

Design notes: bash 3.2-compatible (no associative arrays), zero dependencies beyond `git` +
`kubectl` (+ optional `fzf`/`whiptail`/`gh`), every menu has a typed-input fallback, stdin-EOF
cancels cleanly, and Windows-MSYS path quirks are handled in one place (`lib/github.sh`).
