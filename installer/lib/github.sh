#!/bin/bash
# github.sh — fork + push automation for the installer (Phase 2).
# Kills the #1 cliff: rewritten values MUST reach the user's fork or ArgoCD
# syncs nothing. Automates: auth -> fork -> commit -> push via gh CLI.
#
# Output contract: user-facing lines -> stderr; RESULTS -> stdout.
# Tokens never echoed, never written to remote URLs.

GH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
. "$GH_DIR/common.sh"


UPSTREAM_REPO="${UPSTREAM_REPO:-mysweetpea/homelab-k8s}"

gh_hint() {
  warn "GitHub CLI (gh) is required. Install it:"
  info "  Windows: winget install GitHub.cli"
  info "  macOS:   brew install gh"
  info "  Linux:   sudo apt install gh   (or: dnf install gh)"
}

gh_have() {
  have gh || return 127
  gh auth token >/dev/null 2>&1
}

gh_login() {
  if ! have gh; then gh_hint; return 127; fi
  info "We need one-time access to your GitHub account to:"
  info "  1. Create your copy (fork) of the homelab repository"
  info "  2. Save your settings there so the cluster can update itself"
  info "A browser window will open; paste the code shown here. The token is"
  info "stored in your operating system keychain - never in this folder."
  gh auth login --web --git-protocol https
}

gh_user() {
  have gh || { gh_hint; return 127; }
  local u
  u=$(gh api user --jq .login 2>/dev/null) || return 1
  printf '%s' "$u"
}

# poll until the fork exists; echoes default branch; rc1 on timeout
gh_fork_ready() { # <owner/repo>
  local waited=0 branch
  while [ "$waited" -lt 120 ]; do
    branch=$(gh api "repos/$1" --jq .default_branch 2>/dev/null) && {
      [ -n "$branch" ] && { printf '%s' "$branch"; return 0; }
    }
    sleep 5
    waited=$((waited + 5))
  done
  warn "Timed out waiting for fork $1 to become ready."
  return 1
}

gh_ensure_fork() { # <upstream> -> echoes "<user>/homelab-k8s"
  gh_have || { gh_hint; return 127; }
  local up="$1" out user
  info "Ensuring your fork of $up exists..."
  out=$(gh repo fork "$up" --clone=false --default-branch-only 2>&1) || {
    warn "Fork creation failed: $out"
    return 1
  }
  user=$(gh_user) || return 1
  local slug="$user/${up#*/}"
  gh_fork_ready "$slug" || return 1
  printf '%s' "$slug"
}

gh_push_dir() { # <git_dir> <user/repo> <commit_msg>
  local dir="$1" slug="$2" msg="$3"
  printf 'DBG_PUSH dir=[%s] gitdir=%s
' "$dir" "$([ -d "$dir/.git" ] && echo yes || echo no)" >&2
  [ -d "$dir/.git" ] || { warn "Not a git repository: $dir"; return 1; }

  # identity: only set if unset; prefer noreply address for privacy
  local login uid
  login=$(gh api user --jq .login 2>/dev/null) || login="homelab-user"
  uid=$(gh api user --jq .id 2>/dev/null) || uid="0"
  (cd "$dir" && git config user.name "$login" && git config user.email "${uid}+${login}@users.noreply.github.com")

  (cd "$dir" && git add -A)
  if (cd "$dir" && git diff --cached --quiet) 2>/dev/null; then
    printf 'already-clean'
    return 0
  fi
  (cd "$dir" && git commit -q -m "$msg") || { warn "Commit failed"; return 1; }

  # remote: force origin to the HTTPS form of the user's fork
  # MSP_ORIGIN_OVERRIDE lets tests point origin at a local bare repo.
  local want="${MSP_ORIGIN_OVERRIDE:-https://github.com/$slug.git}"
  local cur
  cur=$(cd "$dir" && git remote get-url origin 2>/dev/null)
  if [ "$cur" != "$want" ]; then
    (cd "$dir" && git remote remove origin 2>/dev/null)
    (cd "$dir" && git remote add origin "$want")
  fi

  # credentials via gh keychain; token never lands in .git/config
  gh auth setup-git >/dev/null 2>&1
  if ! (cd "$dir" && git push -u origin HEAD) 2>&1; then
    warn "Push failed. Run this manually to see the error:"
    info "  cd \"$dir\" && git push -u origin HEAD"
    return 1
  fi
  printf 'pushed'
  return 0
}

gh_sync_upstream() { # <git_dir> <upstream_repo>
  local dir="$1" up="$2"
  [ -d "$dir/.git" ] || { warn "Not a git repository: $dir"; return 1; }
  (cd "$dir" && git remote get-url upstream >/dev/null 2>&1) || \
    (cd "$dir" && git remote add upstream "https://github.com/$up.git")
  (cd "$dir" && git fetch upstream --prune -q) || { warn "Fetch from upstream failed"; return 1; }
  local base
  base=$(cd "$dir" && git merge-base HEAD upstream/main 2>/dev/null)
  local upstream_head
  upstream_head=$(cd "$dir" && git rev-parse upstream/main 2>/dev/null)
  if [ "$base" = "$upstream_head" ]; then
    printf 'up-to-date'
    return 0
  fi
  if (cd "$dir" && git rebase upstream/main) >/dev/null 2>&1; then
    printf 'rebased'
  else
    (cd "$dir" && git rebase --abort) 2>/dev/null
    warn "Upstream rebase conflicts with your changes."
    info "  Resolve manually: cd \"$dir\" && git rebase upstream/main"
    return 1
  fi
}
