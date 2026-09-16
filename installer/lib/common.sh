COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
LIB_DIR="$COMMON_DIR"

if [ -n "${NO_COLOR:-}" ] || [ ! -t 1 ]; then
  C_GREEN=""
  C_YELLOW=""
  C_RED=""
  C_DIM=""
  C_BOLD=""
  C_OFF=""
else
  C_GREEN=$'\033[0;32m'
  C_YELLOW=$'\033[0;33m'
  C_RED=$'\033[0;31m'
  C_DIM=$'\033[2m'
  C_BOLD=$'\033[1m'
  C_OFF=$'\033[0m'
fi

log() {
  printf '%s[+]%s %s\n' "$C_GREEN" "$C_OFF" "$*"
}

warn() {
  printf '%s[!]%s %s\n' "$C_YELLOW" "$C_OFF" "$*" >&2
}

die() {
  printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2
  exit 1
}

info() {
  printf '%s%s%s\n' "$C_DIM" "$*" "$C_OFF"
}

confirm() {
  if [ $# -lt 1 ]; then
    echo "confirm: usage: confirm \"Question?\" [default_y|default_n]" >&2
    return 1
  fi
  local question="$1" default="${2:-default_n}" hint
  local -l answer
  case "$default" in
    default_y) hint="[Y/n]" ;;
    default_n) hint="[y/N]" ;;
    *)
      echo "confirm: default must be default_y or default_n" >&2
      return 1
      ;;
  esac
  while :; do
    printf '%s %s ' "$question" "$hint" >&2
    if ! IFS= read -r answer; then
      [ "$default" = "default_y" ] && return 0
      return 1
    fi
    case "$answer" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      "") [ "$default" = "default_y" ] && return 0 || return 1 ;;
    esac
    echo "Please answer y(es) or n(o)." >&2
  done
}

have() {
  command -v "$1" >/dev/null 2>&1
}
