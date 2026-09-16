CATALOG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

. "$CATALOG_DIR/common.sh"

APPS_N=0
UC_N=0

_catalog_awk() {
  awk '
    BEGIN { sec = ""; app = ""; uc = ""; bad = 0 }
    function err(msg) { printf "ERR\t%s\n", msg; bad = 1; exit 1 }
    function cleanval(v) {
      sub(/\r$/, "", v)
      sub(/^[ ]+/, "", v)
      sub(/[ \t]+$/, "", v)
      if (length(v) >= 2 && substr(v, 1, 1) == "\"" && substr(v, length(v), 1) == "\"")
        v = substr(v, 2, length(v) - 2)
      gsub(/\t/, " ", v)
      return v
    }
    function flushapp() {
      if (app == "") return
      if (!h_cat || !h_desc || !h_ram || !h_def) {
        m = ""
        if (!h_cat) m = m " category"
        if (!h_desc) m = m " description"
        if (!h_ram) m = m " ram_mb"
        if (!h_def) m = m " guided_default"
        err("app " app ": missing required field(s):" m)
      }
      if (v_ram !~ /^[0-9]+$/)
        err("app " app ": ram_mb must be a non-negative integer, got: " v_ram)
      if (v_def != "true" && v_def != "false")
        err("app " app ": guided_default must be true or false, got: " v_def)
    }
    { sub(/\r$/, "") }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    /^[A-Za-z_][A-Za-z0-9_-]*:$/ {
      k = substr($0, 1, length($0) - 1)
      if (k == "apps" || k == "use_cases" || k == "bundles" || k == "secrets") {
        if (sec == "apps") flushapp()
        app = ""
        uc = ""
        sec = k
      } else {
        err("unknown top-level section: " k)
      }
      next
    }
    sec == "bundles" || sec == "secrets" { next }
    sec == "apps" {
      if ($0 ~ /^  [^ ]/) {
        if ($0 !~ /^  [^ ].*:$/)
          err("apps: malformed app header line: " $0)
        flushapp()
        app = substr($0, 3, length($0) - 3)
        if (app in seenapp)
          err("duplicate app: " app)
        seenapp[app] = 1
        h_cat = 0
        h_desc = 0
        h_ram = 0
        h_def = 0
        v_ram = ""
        v_def = ""
        print "APP\t" app
        next
      }
      if ($0 ~ /^    /) {
        if (app == "")
          err("apps: field outside an app block: " $0)
        rest = substr($0, 5)
        c = index(rest, ":")
        if (c < 2)
          err("apps: malformed field line: " $0)
        key = substr(rest, 1, c - 1)
        val = cleanval(substr(rest, c + 1))
        if (key == "category") { h_cat = 1; print "AF\tcategory\t" val }
        else if (key == "description") { h_desc = 1; print "AF\tdescription\t" val }
        else if (key == "ram_mb") { h_ram = 1; v_ram = val; print "AF\tram_mb\t" val }
        else if (key == "requires") { print "AF\trequires\t" val }
        else if (key == "use_cases") { print "AF\tuse_cases\t" val }
        else if (key == "subdomain") { print "AF\tsubdomain\t" val }
        else if (key == "guided_default") { h_def = 1; v_def = val; print "AF\tguided_default\t" val }
        else if (key == "risk") { print "AF\trisk\t" val }
        else err("app " app ": unknown field: " key)
        next
      }
      err("apps: unexpected line: " $0)
    }
    sec == "use_cases" {
      if ($0 ~ /^  [^ ]/) {
        if ($0 !~ /^  [^ ].*:$/)
          err("use_cases: malformed use case header line: " $0)
        uc = substr($0, 3, length($0) - 3)
        if (uc in seenuc)
          err("duplicate use case: " uc)
        seenuc[uc] = 1
        print "UC\t" uc
        next
      }
      if ($0 ~ /^    /) {
        if (uc == "")
          err("use_cases: field outside a use case block: " $0)
        rest = substr($0, 5)
        c = index(rest, ":")
        if (c < 2)
          err("use_cases: malformed field line: " $0)
        key = substr(rest, 1, c - 1)
        val = cleanval(substr(rest, c + 1))
        if (key == "label") print "UF\tlabel\t" val
        else if (key == "description") print "UF\tdescription\t" val
        else err("use case " uc ": unknown field: " key)
        next
      }
      err("use_cases: unexpected line: " $0)
    }
    sec == "" { err("line outside any known section: " $0) }
    END { if (bad == 0 && sec == "apps") flushapp() }
  ' "$1"
}

catalog_load() {
  if [ $# -ne 1 ]; then
    echo "catalog: ERROR: usage: catalog_load <path>" >&2
    return 1
  fi
  if ! have awk; then
    echo "catalog: ERROR: awk not found in PATH" >&2
    return 1
  fi
  local file="$1"
  if [ ! -r "$file" ]; then
    echo "catalog: ERROR: cannot read catalog file: $file" >&2
    return 1
  fi
  local tag f1 f2 cur_app cur_uc parse_err
  cur_app=-1
  cur_uc=-1
  parse_err=""
  APPS_N=0
  UC_N=0
  unset APPS_NAME APPS_CATEGORY APPS_DESC APPS_RAM APPS_REQUIRES APPS_USECASES APPS_SUBDOMAIN APPS_DEFAULT APPS_RISK
  unset UC_ID UC_LABEL UC_DESC
  while IFS=$'\t' read -r tag f1 f2; do
    case "$tag" in
      APP)
        cur_app=$APPS_N
        APPS_NAME[$cur_app]=$f1
        APPS_N=$((APPS_N + 1))
        ;;
      AF)
        case "$f1" in
          category) APPS_CATEGORY[$cur_app]=$f2 ;;
          description) APPS_DESC[$cur_app]=$f2 ;;
          ram_mb) APPS_RAM[$cur_app]=$f2 ;;
          requires) APPS_REQUIRES[$cur_app]=$f2 ;;
          use_cases) APPS_USECASES[$cur_app]=$f2 ;;
          subdomain) APPS_SUBDOMAIN[$cur_app]=$f2 ;;
          guided_default) APPS_DEFAULT[$cur_app]=$f2 ;;
          risk) APPS_RISK[$cur_app]=$f2 ;;
        esac
        ;;
      UC)
        cur_uc=$UC_N
        UC_ID[$cur_uc]=$f1
        UC_N=$((UC_N + 1))
        ;;
      UF)
        case "$f1" in
          label) UC_LABEL[$cur_uc]=$f2 ;;
          description) UC_DESC[$cur_uc]=$f2 ;;
        esac
        ;;
      ERR)
        parse_err=1
        printf 'catalog: ERROR: %s\n' "$f1" >&2
        ;;
    esac
  done < <(_catalog_awk "$file")
  if [ -n "$parse_err" ]; then
    return 1
  fi
  return 0
}

catalog_n() {
  echo "$APPS_N"
}

catalog_index() {
  if [ $# -ne 1 ]; then
    echo "catalog: ERROR: usage: catalog_index <app>" >&2
    return 1
  fi
  local i
  i=0
  while [ "$i" -lt "$APPS_N" ]; do
    if [ "${APPS_NAME[$i]}" = "$1" ]; then
      echo "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

catalog_app() {
  if [ $# -ne 1 ]; then
    echo "catalog: ERROR: usage: catalog_app <app>" >&2
    return 1
  fi
  local idx
  idx=$(catalog_index "$1") || return 1
  printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
    "${APPS_CATEGORY[$idx]:-}" \
    "${APPS_RAM[$idx]:-}" \
    "${APPS_DESC[$idx]:-}" \
    "${APPS_REQUIRES[$idx]:-}" \
    "${APPS_USECASES[$idx]:-}" \
    "${APPS_SUBDOMAIN[$idx]:-}" \
    "${APPS_DEFAULT[$idx]:-}" \
    "${APPS_RISK[$idx]:-}"
}

_clos_visit() {
  local idx="$1" name rest tok tidx w cyc started
  name="${APPS_NAME[$idx]}"
  case "$__CLOS_INSTACK" in
    *" $idx "*)
      cyc=""
      started=0
      for w in $__CLOS_INSTACK; do
        if [ "$started" -eq 1 ] || [ "$w" = "$idx" ]; then
          started=1
          cyc="$cyc ${APPS_NAME[$w]}"
        fi
      done
      echo "dependency cycle detected involving:$cyc" >&2
      return 1
      ;;
  esac
  case "$__CLOS_SEEN" in
    *" $idx "*) return 0 ;;
  esac
  __CLOS_SEEN="$__CLOS_SEEN$idx "
  __CLOS_INSTACK="$__CLOS_INSTACK$idx "
  rest="${APPS_REQUIRES[$idx]:-},"
  while [ -n "$rest" ]; do
    tok="${rest%%,*}"
    rest="${rest#*,}"
    [ -n "$tok" ] || continue
    tidx=$(catalog_index "$tok")
    if [ -z "$tidx" ]; then
      echo "catalog: ERROR: app $name requires unknown app: $tok" >&2
      return 1
    fi
    [ "$tidx" = "$__CLOS_FIRST_IDX" ] && __CLOS_FIRST_DEPPED=1
    _clos_visit "$tidx" || return 1
  done
  __CLOS_INSTACK="${__CLOS_INSTACK/ $idx / }"
  __CLOS_POST[$__CLOS_POST_N]=$idx
  __CLOS_POST_N=$((__CLOS_POST_N + 1))
  return 0
}

catalog_dep_closure() {
  if [ $# -eq 0 ]; then
    echo "catalog: ERROR: usage: catalog_dep_closure <app> [app...]" >&2
    return 1
  fi
  local arg idx i
  __CLOS_SEEN=" "
  __CLOS_INSTACK=" "
  __CLOS_POST_N=0
  __CLOS_FIRST_IDX=""
  __CLOS_FIRST_DEPPED=0
  unset __CLOS_POST
  for arg in "$@"; do
    idx=$(catalog_index "$arg")
    if [ -z "$idx" ]; then
      echo "catalog: ERROR: unknown app: $arg" >&2
      return 1
    fi
    if [ -z "$__CLOS_FIRST_IDX" ]; then
      __CLOS_FIRST_IDX=$idx
    fi
    _clos_visit "$idx" || return 1
  done
  i=0
  while [ "$i" -lt "$__CLOS_POST_N" ]; do
    idx="${__CLOS_POST[$i]}"
    if [ "$idx" = "$__CLOS_FIRST_IDX" ] && [ "$__CLOS_FIRST_DEPPED" -eq 0 ]; then
      i=$((i + 1))
      continue
    fi
    echo "${APPS_NAME[$idx]}"
    i=$((i + 1))
  done
  return 0
}

catalog_by_use_case() {
  if [ $# -ne 1 ]; then
    echo "catalog: ERROR: usage: catalog_by_use_case <use-case-id>" >&2
    return 1
  fi
  local i ucs
  i=0
  while [ "$i" -lt "$APPS_N" ]; do
    ucs=",${APPS_USECASES[$i]:-},"
    case "$ucs" in
      *,"$1",*) echo "${APPS_NAME[$i]}" ;;
    esac
    i=$((i + 1))
  done
  return 0
}

catalog_use_cases() {
  local i
  i=0
  while [ "$i" -lt "$UC_N" ]; do
    echo "${UC_ID[$i]}"
    i=$((i + 1))
  done
  return 0
}

_uc_exists() {
  local i
  i=0
  while [ "$i" -lt "$UC_N" ]; do
    [ "${UC_ID[$i]}" = "$1" ] && return 0
    i=$((i + 1))
  done
  return 1
}

_catalog_bundle_members() {
  awk '
    { sub(/\r$/, "") }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    /^bundles:$/ { inb = 1; next }
    /^[^ \t#]/ { inb = 0; next }
    inb && /^  [^ ]/ { b = 1; next }
    inb && b && /^    - / { m = substr($0, 7); sub(/[ \t]+#.*$/, "", m); sub(/[ \t]+$/, "", m); print m; next }
    inb && b { next }
    { next }
  ' "$1"
}

_catalog_validate_run() {
  (
    file="$1"
    problems=0
    catalog_load "$file" || exit 1
    i=0
    while [ "$i" -lt "$APPS_N" ]; do
      rest="${APPS_REQUIRES[$i]:-},"
      while [ -n "$rest" ]; do
        tok="${rest%%,*}"
        rest="${rest#*,}"
        [ -n "$tok" ] || continue
        if ! catalog_index "$tok" >/dev/null; then
          echo "catalog: ERROR: app ${APPS_NAME[$i]}: requires unknown app: $tok" >&2
          problems=$((problems + 1))
        fi
      done
      rest="${APPS_USECASES[$i]:-},"
      while [ -n "$rest" ]; do
        tok="${rest%%,*}"
        rest="${rest#*,}"
        [ -n "$tok" ] || continue
        if ! _uc_exists "$tok"; then
          echo "catalog: ERROR: app ${APPS_NAME[$i]}: references unknown use case: $tok" >&2
          problems=$((problems + 1))
        fi
      done
      if [ "${APPS_DEFAULT[$i]:-}" = "true" ]; then
        if [ -z "${APPS_CATEGORY[$i]:-}" ] || [ -z "${APPS_DESC[$i]:-}" ] || [ -z "${APPS_RAM[$i]:-}" ]; then
          echo "catalog: ERROR: app ${APPS_NAME[$i]}: guided_default app is missing required fields" >&2
          problems=$((problems + 1))
        fi
      fi
      i=$((i + 1))
    done
    while IFS= read -r member; do
      [ -n "$member" ] || continue
      if ! catalog_index "$member" >/dev/null; then
        echo "catalog: ERROR: bundle member not found in apps: $member" >&2
        problems=$((problems + 1))
      fi
    done < <(_catalog_bundle_members "$file")
    if [ "$problems" -gt 0 ]; then
      exit 1
    fi
    echo "catalog: OK"
  )
}

catalog_validate() {
  if [ $# -ne 1 ]; then
    echo "catalog: ERROR: usage: catalog_validate <path>" >&2
    return 1
  fi
  _catalog_validate_run "$1"
}
