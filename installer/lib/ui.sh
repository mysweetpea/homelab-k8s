#!/bin/bash
# ui.sh — selection library with a backend ladder for the installer wizard.
#
#   MSP_UI=plain / non-TTY  -> plain numbered menus (always works)
#   else fzf in PATH        -> fzf --multi / --multi=0
#   else whiptail in PATH   -> whiptail --checklist / --radiolist
#   else                    -> pure-bash ANSI checkbox (bash 3.2 OK)
#
# CONTRACT: menus/prompts render to STDERR; selected ids go to STDOUT,
# one per line. Returns 0 on success, 1 on cancel. The ansi backend
# returns 2 when stdin is not a TTY (callers may fall back to plain).

UI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$UI_DIR/common.sh"

UI_BACKEND=""
printf -v _UI_CR "\r"

# fractional read -t needs bash >= 4; probe once (rc 1 = ok, 2 = rejected).
_ui_frac=0
bash -c 'read -t 0.05 _uix </dev/null' 2>/dev/null
[ $? -eq 1 ] && _ui_frac=1
_ui_key_timeout() {
  if [ "$_ui_frac" = 1 ]; then printf '0.05'; else printf '1'; fi
}

ui_init() {
  case "${MSP_UI:-}" in
    plain)    UI_BACKEND=plain;    return 0 ;;
    fzf)      UI_BACKEND=fzf;      return 0 ;;
    whiptail) UI_BACKEND=whiptail; return 0 ;;
    ansi)     UI_BACKEND=ansi;     return 0 ;;
    "") : ;;
    *) warn "ui: unknown MSP_UI='$MSP_UI', auto-detecting" ;;
  esac
  if [ -t 0 ] && [ -t 1 ] && [ -n "${TERM:-}" ] && [ "${TERM:-}" != "dumb" ]; then
    if have fzf; then
      UI_BACKEND=fzf
    elif have whiptail; then
      UI_BACKEND=whiptail
    else
      UI_BACKEND=ansi
    fi
  else
    UI_BACKEND=plain
  fi
  return 0
}

# ---- rowspec splitters ----------------------------------------------------
_ui_split2() {           # "id|rest"        -> _ui_id _ui_rest
  _ui_id="${1%%|*}"
  _ui_rest="${1#*|}"
  [ "$_ui_rest" = "$1" ] && _ui_rest=""
  return 0
}
_ui_split3() {           # "id|state|rest"  -> _ui_id _ui_state _ui_rest
  _ui_id="${1%%|*}"
  local r="${1#*|}"
  _ui_state="${r%%|*}"
  _ui_rest="${r#*|}"
  [ "$_ui_rest" = "$r" ] && _ui_rest=""
  return 0
}
_ui_is_header() {  # arg: an id; true if header row
  case "$1" in "#"*) return 0 ;; *) return 1 ;; esac
}

# ---- plain backends -------------------------------------------------------
_ui_single_plain() {
  local title="$1"; shift
  local rows=("$@") n=${#rows[@]} line i
  while :; do
    printf '%s\n' "$title" >&2
    for ((i=0; i<n; i++)); do
      _ui_split2 "${rows[$i]}"
      printf '%2d) %s\n' "$((i+1))" "$_ui_rest" >&2
    done
    printf 'Pick a number (Enter re-shows, q cancels): ' >&2
    IFS= read -r line || line="q"
    case "$line" in
      q|Q) return 1 ;;
      "") : ;;
      *[!0-9]*) : ;;
      *) i=$((line-1))
         if [ "$i" -ge 0 ] && [ "$i" -lt "$n" ]; then
           _ui_split2 "${rows[$i]}"
           printf '%s\n' "$_ui_id"
           return 0
         fi ;;
    esac
  done
}

_ui_multi_plain() {
  local title="$1"; shift
  local rows=("$@") n=${#rows[@]} i line w m
  local states=() selectable=()
  for ((i=0; i<n; i++)); do
    _ui_split3 "${rows[$i]}"
    states[$i]="$_ui_state"
    if _ui_is_header "$_ui_id"; then selectable[$i]=0; else selectable[$i]=1; fi
  done
  while :; do
    printf '%s\n' "$title" >&2
    for ((i=0; i<n; i++)); do
      _ui_split3 "${rows[$i]}"
      if [ "${selectable[$i]}" = 0 ]; then
        printf '%s\n' "$_ui_rest" >&2
      else
        m=" "; [ "${states[$i]}" = "x" ] && m="x"
        printf '%2d) [%s] %s\n' "$((i+1))" "$m" "$_ui_rest" >&2
      fi
    done
    printf 'Numbers to toggle (spaces/commas), a=all, n=none, Enter=confirm, q=cancel: ' >&2
    IFS= read -r line || { warn "Input closed - cancelling."; return 1; }
    case "$line" in
      q|Q) return 1 ;;
      a|A) for ((i=0; i<n; i++)); do
             [ "${selectable[$i]}" = 1 ] && states[$i]="x"
           done ;;
      n|N) for ((i=0; i<n; i++)); do
             [ "${selectable[$i]}" = 1 ] && states[$i]=" "
           done ;;
      "") break ;;
      *)  line="${line//,/ }"
          for w in $line; do
            case "$w" in
              ""|*[!0-9]*) : ;;
              *) i=$((w-1))
                 if [ "$i" -ge 0 ] && [ "$i" -lt "$n" ] && [ "${selectable[$i]}" = 1 ]; then
                   if [ "${states[$i]}" = "x" ]; then states[$i]=" "; else states[$i]="x"; fi
                 fi ;;
            esac
          done ;;
    esac
  done
  for ((i=0; i<n; i++)); do
    if [ "${selectable[$i]}" = 1 ] && [ "${states[$i]}" = "x" ]; then
      _ui_split3 "${rows[$i]}"
      printf '%s\n' "$_ui_id"
    fi
  done
  return 0
}

# ---- ansi backends --------------------------------------------------------
_UI_DRAWN=0
_ui_ansi_cleanup() {
  printf '\033[?25h' >&2
}
_ui_ansi_up() {
  [ "$_UI_DRAWN" -gt 0 ] && printf '\033[%dA' "$_UI_DRAWN" >&2
  return 0
}

_ui_multi_ansi() {
  local title="$1"; shift
  if [ ! -t 0 ] && [ "${MSP_UI_ANSI_FORCE:-0}" != "1" ]; then
    return 2
  fi
  local rows=("$@") n=${#rows[@]} i key k2 k3 m mark
  local states=() selectable=()
  for ((i=0; i<n; i++)); do
    _ui_split3 "${rows[$i]}"
    states[$i]="$_ui_state"
    if _ui_is_header "$_ui_id"; then selectable[$i]=0; else selectable[$i]=1; fi
  done
  local cur=0
  for ((i=0; i<n; i++)); do
    if [ "${selectable[$i]}" = 1 ]; then cur=$i; break; fi
  done

  _ui_next_row() {
    local j=$cur tries=0
    while :; do
      j=$(( (j+1) % n )); tries=$((tries+1))
      if [ "${selectable[$j]}" = 1 ]; then cur=$j; return 0; fi
      [ "$tries" -ge "$n" ] && return 0
    done
  }
  _ui_prev_row() {
    local j=$cur tries=0
    while :; do
      j=$(( (j-1+n) % n )); tries=$((tries+1))
      if [ "${selectable[$j]}" = 1 ]; then cur=$j; return 0; fi
      [ "$tries" -ge "$n" ] && return 0
    done
  }

  printf '%s\n' "$title" >&2
  printf '\033[?25l' >&2
  if [ -z "$(trap -p EXIT)" ]; then
    trap '_ui_ansi_cleanup 2>/dev/null' EXIT
  fi

  local tmo; tmo="$(_ui_key_timeout)"
  _UI_DRAWN=0
  while :; do
    _ui_ansi_up
    for ((i=0; i<n; i++)); do
      _ui_split3 "${rows[$i]}"
      if [ "${selectable[$i]}" = 0 ]; then
        printf '\033[1m%s\033[0K\033[0m\n' "$_ui_rest" >&2
      else
        m=" "; [ "${states[$i]}" = "x" ] && m="x"
        mark=" "; [ "$i" = "$cur" ] && mark=">"
        printf '%s %2d) [%s] %s\033[0K\n' "$mark" "$((i+1))" "$m" "$_ui_rest" >&2
      fi
    done
    printf 'j/k move  space toggle  a all  n none  Enter confirm  q cancel\033[0K\n' >&2
    _UI_DRAWN=$((n+1))
    IFS= read -rsn1 key || { warn "Input closed - cancelling."; return 1; }
    [ "$key" = "$_UI_CR" ] && key=""
    case "$key" in
      "") break ;;
      j|J) _ui_next_row ;;
      k|K) _ui_prev_row ;;
      " ") if [ "${selectable[$cur]}" = 1 ]; then
             if [ "${states[$cur]}" = "x" ]; then states[$cur]=" "; else states[$cur]="x"; fi
           fi ;;
      a|A) for ((i=0; i<n; i++)); do
             [ "${selectable[$i]}" = 1 ] && states[$i]="x"
           done ;;
      n|N) for ((i=0; i<n; i++)); do
             [ "${selectable[$i]}" = 1 ] && states[$i]=" "
           done ;;
      q|Q) _ui_ansi_cleanup; return 1 ;;
      [0-9]) local t=$((key-1))
             if [ "$t" -ge 0 ] && [ "$t" -lt "$n" ] && [ "${selectable[$t]}" = 1 ]; then
               cur=$t
             fi ;;
      $'\033')
           if read -rsn1 -t "$tmo" k2; then
             if [ "$k2" = "[" ]; then
               if read -rsn1 -t "$tmo" k3; then
                 case "$k3" in
                   A) _ui_prev_row ;;
                   B) _ui_next_row ;;
                 esac
               fi
             fi
           else
             _ui_ansi_cleanup; return 1            # lone Esc = cancel
           fi ;;
    esac
  done
  _ui_ansi_cleanup
  printf '\n' >&2
  for ((i=0; i<n; i++)); do
    if [ "${selectable[$i]}" = 1 ] && [ "${states[$i]}" = "x" ]; then
      _ui_split3 "${rows[$i]}"
      printf '%s\n' "$_ui_id"
    fi
  done
  _UI_DRAWN=0
  return 0
}

_ui_single_ansi() {
  local title="$1"; shift
  if [ ! -t 0 ] && [ "${MSP_UI_ANSI_FORCE:-0}" != "1" ]; then
    return 2
  fi
  local rows=("$@") n=${#rows[@]} i key k2 k3 m mk
  local mark=()
  for ((i=0; i<n; i++)); do mark[$i]=0; done
  local cur=0

  printf '%s\n' "$title" >&2
  printf '\033[?25l' >&2
  if [ -z "$(trap -p EXIT)" ]; then
    trap '_ui_ansi_cleanup 2>/dev/null' EXIT
  fi
  local tmo; tmo="$(_ui_key_timeout)"
  _UI_DRAWN=0
  while :; do
    _ui_ansi_up
    for ((i=0; i<n; i++)); do
      _ui_split2 "${rows[$i]}"
      m=" "; [ "${mark[$i]}" = 1 ] && m="x"
      mk=" "; [ "$i" = "$cur" ] && mk=">"
      printf '%s %2d) %s\033[0K\n' "$mk" "$((i+1))" "$_ui_rest" >&2
    done
    printf 'space pick  Enter confirm  q cancel\033[0K\n' >&2
    _UI_DRAWN=$((n+1))
    IFS= read -rsn1 key || { warn "Input closed - cancelling."; return 1; }
    [ "$key" = "$_UI_CR" ] && key=""
    case "$key" in
      "") mark[$cur]=1; break ;;
      j|J) [ "$n" -gt 0 ] && cur=$(( (cur+1) % n )) ;;
      k|K) [ "$n" -gt 0 ] && cur=$(( (cur-1+n) % n )) ;;
      " ") local j; for ((j=0; j<n; j++)); do mark[$j]=0; done
           mark[$cur]=1
           [ "$n" -gt 0 ] && cur=$(( (cur+1) % n )) ;;
      q|Q) _ui_ansi_cleanup; return 1 ;;
      $'\033')
           if read -rsn1 -t "$tmo" k2; then
             if [ "$k2" = "[" ]; then
               if read -rsn1 -t "$tmo" k3; then
                 case "$k3" in
                   A) [ "$n" -gt 0 ] && cur=$(( (cur-1+n) % n )) ;;
                   B) [ "$n" -gt 0 ] && cur=$(( (cur+1) % n )) ;;
                 esac
               fi
             fi
           else
             _ui_ansi_cleanup; return 1
           fi ;;
    esac
  done
  _ui_ansi_cleanup
  printf '\n' >&2
  for ((i=0; i<n; i++)); do
    if [ "${mark[$i]}" = 1 ]; then
      _ui_split2 "${rows[$i]}"
      printf '%s\n' "$_ui_id"
      _UI_DRAWN=0
      return 0
    fi
  done
  _UI_DRAWN=0
  return 1
}

# ---- fzf backends ---------------------------------------------------------
_ui_multi_fzf() {
  local title="$1"; shift
  local rows=("$@") i
  local filtered=() pre=() pre_idx=()
  for ((i=0; i<${#rows[@]}; i++)); do
    _ui_split3 "${rows[$i]}"
    if _ui_is_header "$_ui_id"; then continue; fi
    filtered+=("${rows[$i]}")
    [ "$_ui_state" = "x" ] && pre_idx+=(${#filtered[@]}-1)
  done
  [ ${#filtered[@]} -eq 0 ] && return 1
  local fzf_args=(--multi --height=60% --reverse --delimiter='|' --with-nth=3 --header="$title")
  if [ ${#pre_idx[@]} -gt 0 ] && fzf --help 2>&1 | grep -q -- '--preselect'; then
    fzf_args+=(--preselect="${pre_idx[*]}")
  fi
  local out line
  out=$(printf '%s\n' "${filtered[@]}" | fzf "${fzf_args[@]}") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] && printf '%s\n' "${line%%|*}"
  done <<EOF
$out
EOF
  return 0
}

_ui_single_fzf() {
  local title="$1"; shift
  local out
  out=$(printf '%s\n' "$@" | fzf --multi=0 --height=40% --reverse --delimiter='|' --with-nth=2 --header="$title") || return 1
  printf '%s\n' "${out%%|*}"
  return 0
}

# ---- whiptail backends ----------------------------------------------------
_ui_multi_whiptail() {
  local title="$1"; shift
  local rows=("$@") i args=()
  for ((i=0; i<${#rows[@]}; i++)); do
    _ui_split3 "${rows[$i]}"
    if _ui_is_header "$_ui_id"; then continue; fi
    local on="OFF"; [ "$_ui_state" = "x" ] && on="ON"
    args+=("$_ui_id" "$_ui_rest" "$on")
  done
  [ ${#args[@]} -eq 0 ] && return 1
  local out id
  out=$(whiptail --title "$title" --checklist "" 0 0 0 "${args[@]}" 3>&1 1>&2 2>&3) || return 1
  for id in $out; do
    id="${id%\"}"; id="${id#\"}"
    printf '%s\n' "$id"
  done
  return 0
}

_ui_single_whiptail() {
  local title="$1"; shift
  local rows=("$@") i args=()
  for ((i=0; i<${#rows[@]}; i++)); do
    _ui_split2 "${rows[$i]}"
    args+=("$_ui_id" "$_ui_rest" "OFF")
  done
  local out
  out=$(whiptail --title "$title" --radiolist "" 0 0 0 "${args[@]}" 3>&1 1>&2 2>&3) || return 1
  out="${out%\"}"; out="${out#\"}"
  printf '%s\n' "$out"
  return 0
}

# ---- dispatchers ----------------------------------------------------------
ui_single_select() {     # TITLE [SEP] ROWSPEC...  -> chosen id on stdout
  local title="$1"; shift
  local sep="|"
  if [ "$#" -gt 1 ]; then
    sep="$1"; shift
  fi
  local rows=("$@") i
  if [ "$sep" != "|" ]; then
    for ((i=0; i<${#rows[@]}; i++)); do rows[$i]="${rows[$i]//$sep/|}"; done
  fi
  ui_init
  case "$UI_BACKEND" in
    fzf)      if have fzf; then _ui_single_fzf "$title" "${rows[@]}"; return $?; fi ;;
    whiptail) if have whiptail; then _ui_single_whiptail "$title" "${rows[@]}"; return $?; fi ;;
    ansi)     local rc
              _ui_single_ansi "$title" "${rows[@]}"; rc=$?
              if [ "$rc" = 2 ]; then
                _ui_single_plain "$title" "${rows[@]}"; return $?
              fi
              return "$rc" ;;
  esac
  _ui_single_plain "$title" "${rows[@]}"
}

ui_multi_select() {      # TITLE ROWSPEC... -> selected ids on stdout
  local title="$1"; shift
  local rows=("$@")
  ui_init
  case "$UI_BACKEND" in
    fzf)      if have fzf; then _ui_multi_fzf "$title" "${rows[@]}"; return $?; fi ;;
    whiptail) if have whiptail; then _ui_multi_whiptail "$title" "${rows[@]}"; return $?; fi ;;
    ansi)     local rc
              _ui_multi_ansi "$title" "${rows[@]}"; rc=$?
              if [ "$rc" = 2 ]; then
                _ui_multi_plain "$title" "${rows[@]}"; return $?
              fi
              return "$rc" ;;
  esac
  _ui_multi_plain "$title" "${rows[@]}"
}
