# shellcheck shell=bash
# ===========================================================================
# pi-system — memory-budget LIBRARY (pure logic + mockable seams)
# ---------------------------------------------------------------------------
# SOURCED by scripts/mem-budget.sh and by the test harness in tests/mem-budget/.
# It mirrors scripts/lib/preflight-lib.sh exactly in spirit:
#
#   1. PURE functions — parse a compose file's memory limits, convert memory
#      values to MiB, expand a boot profile into its members, and turn a
#      (used, safe) pair into a PASS/WARN/FAIL verdict. They take their inputs
#      as arguments / a given file, so the tests verify the math WITHOUT Docker
#      or a real Pi.
#
#   2. SEAM functions — thin wrappers around the only external inputs: which
#      compose files to scan, where the profile config lives, and the host's
#      total RAM (/proc/meminfo). A test redefines any of these to inject a
#      fixed value, so the same logic runs offline and on the Pi.
#
# DESIGN RULES (kept identical to preflight-lib.sh so the two feel the same):
#   * READ-ONLY: nothing here starts/stops a container, writes a secret, or
#     mutates state. It only reads text files and /proc/meminfo. It never prints
#     a secret (memory limits are not secrets, and that is all it reads).
#   * NO `set -e` here — this is a library; the entrypoint owns shell options.
#   * Classifier functions print their verdict to stdout and `return 0`, so a
#     caller's `set -e` is never tripped by a verdict that happens to be FAIL.
#   * The per-service memory LIMITS are read from the compose files themselves
#     (single source of truth) — they are NOT duplicated here.
# ===========================================================================

# Guard against double-sourcing (the entrypoint and tests may both source it).
if [[ -n "${MB_LIB_SOURCED:-}" ]]; then return 0 2>/dev/null || true; fi
MB_LIB_SOURCED=1

# ---------------------------------------------------------------------------
# Verdict vocabulary + tunable constant.
# ---------------------------------------------------------------------------
readonly MB_PASS="PASS"
readonly MB_WARN="WARN"
readonly MB_FAIL="FAIL"
# Used memory above this percentage of the SAFE budget is a WARN (getting full,
# little room left for the page cache, builds, or another service). FAIL is only
# when the sum actually EXCEEDS the safe budget.
readonly MB_WARN_PCT=85

# ===========================================================================
# SECTION 1 — PURE parsers / converters / classifiers (the test surface)
# ===========================================================================

# --- Convert a COMPOSE memory value to integer MiB -------------------------
# Accepts the forms Docker/Compose accept: a bare integer is BYTES; a suffix of
# b / k|kb / m|mb / g|gb / t|tb is a power of 1024 (case-insensitive). Quotes and
# surrounding whitespace are tolerated. Echoes the value in MiB (floored for sub-
# MiB byte counts). Returns non-zero with NO output for an unparseable value.
mb_to_mib() {
  local raw="${1:-}" num unit lower
  raw="${raw//\"/}"; raw="${raw//\'/}"
  raw="${raw#"${raw%%[![:space:]]*}"}"     # ltrim
  raw="${raw%"${raw##*[![:space:]]}"}"     # rtrim
  [[ -n "${raw}" ]] || return 1
  if [[ "${raw}" =~ ^([0-9]+)([A-Za-z]*)$ ]]; then
    num="${BASH_REMATCH[1]}"; unit="${BASH_REMATCH[2]}"
  else
    return 1
  fi
  lower="${unit,,}"
  case "${lower}" in
    ""|b)  echo $(( num / 1048576 )) ;;     # bytes  -> MiB
    k|kb)  echo $(( num / 1024 )) ;;        # KiB    -> MiB
    m|mb)  echo $(( num )) ;;               # MiB
    g|gb)  echo $(( num * 1024 )) ;;        # GiB    -> MiB
    t|tb)  echo $(( num * 1048576 )) ;;     # TiB    -> MiB
    *)     return 1 ;;
  esac
  return 0
}

# --- Convert a PROFILE "label=MiB" allowance to MiB ------------------------
# Differs from mb_to_mib in ONE way: a bare integer means MiB (operators plan in
# megabytes), not bytes. A unit suffix still works (e.g. =1G -> 1024). Returns
# non-zero with no output if unparseable.
mb_literal_mib() {
  local v="${1:-}"
  v="${v//\"/}"; v="${v//\'/}"
  v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
  [[ -n "${v}" ]] || return 1
  if [[ "${v}" =~ ^[0-9]+$ ]]; then echo "${v}"; return 0; fi
  mb_to_mib "${v}"
}

# --- Raw memory tokens in a compose file (awk; one record per line) --------
# Emits two record kinds, TAB-separated, in file order:
#     <service><TAB>              -> a service was DEFINED (registers it; no value)
#     <service><TAB><rawvalue>    -> a memory:/mem_limit: value inside that service
# A service name is a key at EXACTLY two-space indent inside the top-level
# `services:` block (the platform's compose convention). Both
# deploy.resources.limits.memory and a top-level mem_limit are emitted; the bash
# layer (mb_service_limits) takes the MAX so a reservations.memory (always <= the
# limit) can never be mistaken for the cap. Quotes are left for mb_to_mib.
_mb_awk_limits() {
  [[ -f "$1" ]] || return 0
  awk '
    # Any column-0 key toggles whether we are inside the services: block.
    /^[A-Za-z_][A-Za-z0-9_.-]*:/ {
      if ($0 ~ /^services:/) { insvc = 1 } else { insvc = 0; svc = "" }
      next
    }
    # A service definition: exactly two leading spaces, a name, a colon, EOL.
    insvc && /^  [A-Za-z0-9._-]+:[ \t]*$/ {
      name = $0; sub(/:[ \t]*$/, "", name); sub(/^  +/, "", name)
      svc = name; print svc "\t"; next
    }
    # memory: <value> (under deploy.resources.limits or .reservations).
    insvc && svc != "" && /^[ \t]+memory:[ \t]*[^ \t#]/ {
      v = $0; sub(/^[ \t]+memory:[ \t]*/, "", v); sub(/[ \t]*(#.*)?$/, "", v)
      if (v != "") print svc "\t" v; next
    }
    # mem_limit: <value> (the Compose-v2 short form).
    insvc && svc != "" && /^[ \t]+mem_limit:[ \t]*[^ \t#]/ {
      v = $0; sub(/^[ \t]+mem_limit:[ \t]*/, "", v); sub(/[ \t]*(#.*)?$/, "", v)
      if (v != "") print svc "\t" v; next
    }
  ' "$1" 2>/dev/null || true
}

# --- service -> MiB for ONE compose file -----------------------------------
# Echoes "<service><TAB><mib>" per service in file order. <mib> is EMPTY when the
# service declares no (parseable) memory limit — that empty value IS the
# missing-limit signal the budget tool flags. When several memory values exist
# for a service (limits + reservations), the MAX wins (= the hard cap).
mb_service_limits() {
  local file="$1" svc raw mib cur
  local -a order=()
  local -A seen=() maxmib=()
  [[ -f "${file}" ]] || return 0
  while IFS=$'\t' read -r svc raw; do
    [[ -n "${svc}" ]] || continue
    if [[ -z "${seen[${svc}]:-}" ]]; then
      seen[${svc}]=1; order+=("${svc}"); maxmib[${svc}]=""
    fi
    [[ -n "${raw}" ]] || continue
    mib="$(mb_to_mib "${raw}")" || continue
    cur="${maxmib[${svc}]}"
    if [[ -z "${cur}" || "${mib}" -gt "${cur}" ]]; then maxmib[${svc}]="${mib}"; fi
  done < <(_mb_awk_limits "${file}")
  local s
  for s in "${order[@]}"; do printf '%s\t%s\n' "${s}" "${maxmib[${s}]}"; done
  return 0
}

# --- Does a profile config define NAME? ------------------------------------
mb_profile_exists() {
  local conf="$1" name="$2"
  [[ -f "${conf}" ]] || return 1
  grep -qE "^[[:space:]]*${name}[[:space:]]*:" "${conf}"
}

# --- Members of a profile (one token per line) -----------------------------
# Reads the FIRST matching "name:" line, drops a trailing comment, and splits
# on commas/whitespace. Members may be services, other profiles, or label=MiB.
mb_profile_members() {
  local conf="$1" name="$2" line val
  [[ -f "${conf}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${name}[[:space:]]*:" "${conf}" 2>/dev/null | head -n1)"
  [[ -n "${line}" ]] || return 0
  val="${line#*:}"        # drop "name:"
  val="${val%%#*}"        # drop trailing comment
  val="${val//,/ }"       # commas -> spaces
  # Intentional word-split; tokens never contain spaces or globs.
  local t
  for t in ${val}; do [[ -n "${t}" ]] && printf '%s\n' "${t}"; done
  return 0
}

# --- Flatten tokens: expand profiles, keep services/literals (dedup, ordered)
# Any token that names a profile is replaced (depth-first) by its members; a
# service name or label=MiB token passes through unchanged. Profiles are
# expanded at most once (cycle/duplicate guard), and the final list is
# de-duplicated preserving first-seen order. PURE given the conf path (it only
# reads the profile config via mb_profile_exists/_members).
mb_flatten() {
  local conf="$1"; shift
  local -a queue=("$@")
  local -a result=()
  local -A visited=() in_result=()
  local tok
  while ((${#queue[@]})); do
    tok="${queue[0]}"
    queue=("${queue[@]:1}")
    [[ -n "${tok}" ]] || continue
    if mb_profile_exists "${conf}" "${tok}"; then
      [[ -n "${visited[${tok}]:-}" ]] && continue       # already expanded
      visited[${tok}]=1
      local -a members=()
      mapfile -t members < <(mb_profile_members "${conf}" "${tok}")
      # Depth-first: members come before the rest of the queue.
      if ((${#members[@]})); then
        queue=("${members[@]}" ${queue[@]+"${queue[@]}"})
      fi
    else
      if [[ -z "${in_result[${tok}]:-}" ]]; then
        in_result[${tok}]=1; result+=("${tok}")
      fi
    fi
  done
  ((${#result[@]})) && printf '%s\n' "${result[@]}"
  return 0
}

# --- Budget math -----------------------------------------------------------
# Safe budget = total RAM minus the OS/Docker/page-cache reserve (never < 0).
mb_safe_mib() {
  local total="$1" reserve="$2"
  if (( reserve >= total )); then echo 0; else echo $(( total - reserve )); fi
}

# Numeric verdict for a (used, safe) pair, in MiB:
#   FAIL  used exceeds the safe budget (or there is no safe budget at all)
#   WARN  used is within MB_WARN_PCT%..100% of the safe budget (getting full)
#   PASS  comfortably under
mb_verdict_numeric() {
  local used="$1" safe="$2"
  if (( safe <= 0 ));               then echo "${MB_FAIL}"; return 0; fi
  if (( used > safe ));             then echo "${MB_FAIL}"; return 0; fi
  if (( used * 100 > safe * MB_WARN_PCT )); then echo "${MB_WARN}"; return 0; fi
  echo "${MB_PASS}"
}

# Overall verdict: a missing limit ALWAYS forces FAIL (an unbounded container
# can starve the others, which defeats the whole budget), otherwise it is the
# numeric verdict. MISSING is the count of selected services with no limit.
mb_overall_verdict() {
  local missing="$1" used="$2" safe="$3"
  if (( missing > 0 )); then echo "${MB_FAIL}"; return 0; fi
  mb_verdict_numeric "${used}" "${safe}"
}

# ===========================================================================
# SECTION 2 — SEAMS (the only external inputs; redefined by tests)
# ===========================================================================

# Which compose files to scan for service memory limits. Defaults to the
# platform management file plus every services/**/*.compose.yml (so generated
# PROJECT services are auto-included), and deliberately EXCLUDES templates/
# (those carry placeholder service names). MB_PROJECT_ROOT pins the root.
mb_compose_files() {
  local root="${MB_PROJECT_ROOT:-.}"
  [[ -f "${root}/infrastructure/management.compose.yml" ]] \
    && printf '%s\n' "${root}/infrastructure/management.compose.yml"
  if [[ -d "${root}/services" ]]; then
    find "${root}/services" -type f -name '*.compose.yml' 2>/dev/null | sort
  fi
  return 0
}

# Path to the boot-profiles config (overridable for planning / tests).
mb_profile_conf() {
  printf '%s\n' "${MB_PROFILE_CONF:-${MB_PROJECT_ROOT:-.}/infrastructure/boot-profiles.conf}"
}

# Host total RAM in MiB (from /proc/meminfo; empty if unavailable, e.g. a non-
# Linux dev box — the entrypoint then requires --ram).
mb_meminfo_total_mib() {
  awk '/^MemTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || true
}

# ===========================================================================
# SECTION 3 — Builders that compose the seams + pure parsers
# ===========================================================================

# Build the global service -> MiB map across all scanned compose files. Echoes
# "<service><TAB><mib>" (mib empty = missing limit), de-duplicated across files
# by taking the MAX known limit, in first-seen order. Uses the mb_compose_files
# seam, so tests can point it at fixtures.
mb_build_service_map() {
  local f svc mib cur
  local -a order=()
  local -A seen=() maxmib=()
  while IFS= read -r f; do
    [[ -n "${f}" && -f "${f}" ]] || continue
    while IFS=$'\t' read -r svc mib; do
      [[ -n "${svc}" ]] || continue
      if [[ -z "${seen[${svc}]:-}" ]]; then
        seen[${svc}]=1; order+=("${svc}"); maxmib[${svc}]=""
      fi
      [[ -n "${mib}" ]] || continue
      cur="${maxmib[${svc}]}"
      if [[ -z "${cur}" || "${mib}" -gt "${cur}" ]]; then maxmib[${svc}]="${mib}"; fi
    done < <(mb_service_limits "${f}")
  done < <(mb_compose_files)
  local s
  for s in "${order[@]}"; do printf '%s\t%s\n' "${s}" "${maxmib[${s}]}"; done
  return 0
}

# Names of all profiles defined in the config, in file order.
mb_profile_names() {
  local conf="$1"
  [[ -f "${conf}" ]] || return 0
  grep -E '^[[:space:]]*[A-Za-z0-9._-]+[[:space:]]*:' "${conf}" 2>/dev/null \
    | sed -E 's/^[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*:.*$/\1/' \
    || true
  return 0
}
