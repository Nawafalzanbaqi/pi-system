#!/usr/bin/env bash
# ===========================================================================
# pi-system — MEMORY BUDGET planner  (READ-ONLY)
# ---------------------------------------------------------------------------
# Sum the declared memory limits of a BOOT PROFILE (or an explicit list of
# services / profiles) and compare the total against the Pi's RAM, reserving a
# sane amount for the OS, Docker and the page cache. Prints a per-service
# breakdown, the total, the headroom, and a PASS / WARN / FAIL verdict — so you
# never accidentally bring up a set of services that would exhaust the Pi.
#
# Run it AFTER preflight and BEFORE `up`:
#     ./scripts/preflight.sh                 # is the host ready at all?
#     ./scripts/mem-budget.sh auth           # does this profile fit in RAM?
#     ./scripts/auth.sh up                    # ... then bring it up
#
# It is STRICTLY READ-ONLY: it only reads the compose files (for each service's
# deploy.resources.limits.memory), infrastructure/boot-profiles.conf (for the
# profile -> members mapping) and /proc/meminfo (for total RAM). It NEVER starts
# or stops a container, pulls an image, writes anything, or prints a secret.
# It does not even need Docker.
#
# Usage:
#     ./scripts/mem-budget.sh [options] [profile|service|label=MiB ...]
#
#   (no args)             List the known boot profiles + their footprints.
#   --list                Same as no args (profiles + footprints + verdicts).
#   --table               Print every service and its declared limit (the
#                         memory-limit source-of-truth, straight from compose).
#   --ram MiB             Override detected total RAM (for planning, e.g. 8192
#                         to model an 8 GB Pi, 16384 for 16 GB).
#   --os-reserve MiB      RAM to hold back for the OS/Docker/page cache.
#                         Default ${DEFAULT_OS_RESERVE} MiB.
#   --profiles-file PATH  Use a different boot-profiles file.
#   -q, --quiet           Print only the verdict line (and FAILs).
#   -h, --help            Show this help and exit.
#
# A MEMBER is a service name (limit read from compose), another profile
# (expanded), or label=MiB (a literal allowance for planning, e.g. a project).
#
# Exit code: 0 on PASS or WARN, 1 on FAIL (sum exceeds the safe budget, or a
# selected service has NO memory limit), 2 on a usage error.
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Load the pure-logic library (parsers, verdict math, seams) ------------
LIB="${SCRIPT_DIR}/lib/mem-budget-lib.sh"
if [[ ! -f "${LIB}" ]]; then
  printf '\033[0;31m[error]\033[0m Missing required library: %s\n' "${LIB}" >&2
  exit 2
fi
# shellcheck source=scripts/lib/mem-budget-lib.sh
source "${LIB}"

# The library's seams resolve paths relative to this root.
export MB_PROJECT_ROOT="${PROJECT_ROOT}"

# --- Tunables (overridable via flags) --------------------------------------
DEFAULT_OS_RESERVE=1024     # MiB held back for the OS + Docker + page cache
OS_RESERVE="${DEFAULT_OS_RESERVE}"
RAM_OVERRIDE=""             # MiB; empty => detect from /proc/meminfo
QUIET=0
MODE="compute"             # compute | list | table
declare -a TOKENS=()

# --- Colours (off when not a TTY, or NO_COLOR set) -------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_CYAN=$'\033[1;36m';  C_BOLD=$'\033[1m';      C_OFF=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_BOLD=''; C_OFF=''
fi
err() { printf '%s[error]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }

usage() {
  cat >&2 <<EOF
Usage: ./scripts/mem-budget.sh [options] [profile|service|label=MiB ...]

  (no args)             List the known boot profiles + their footprints.
  --list                Same as no args.
  --table               Print every service and its declared memory limit
                        (the source-of-truth, read straight from compose).
  --ram MiB             Override detected total RAM (e.g. 8192 / 16384 for
                        planning an 8 GB / 16 GB Pi).
  --os-reserve MiB      RAM held back for the OS/Docker/page cache (default ${DEFAULT_OS_RESERVE}).
  --profiles-file PATH  Use a different boot-profiles file.
  -q, --quiet           Print only the verdict line (and FAILs).
  -h, --help            Show this help and exit.

Members are services (limit read from compose), other profiles (expanded), or
label=MiB literal allowances (e.g. a project you plan to host).

READ-ONLY: never starts/stops services, pulls images, writes, or prints secrets.
Exit code: 0 on PASS/WARN, 1 on FAIL, 2 on a usage error.
EOF
}

# --- Parse arguments -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    --list)      MODE="list"; shift ;;
    --table)     MODE="table"; shift ;;
    -q|--quiet)  QUIET=1; shift ;;
    --ram)       [[ $# -ge 2 ]] || { err "--ram requires a value (MiB)."; exit 2; }
                 RAM_OVERRIDE="$2"; shift 2 ;;
    --ram=*)     RAM_OVERRIDE="${1#*=}"; shift ;;
    --os-reserve) [[ $# -ge 2 ]] || { err "--os-reserve requires a value (MiB)."; exit 2; }
                 OS_RESERVE="$2"; shift 2 ;;
    --os-reserve=*) OS_RESERVE="${1#*=}"; shift ;;
    --profiles-file) [[ $# -ge 2 ]] || { err "--profiles-file requires a path."; exit 2; }
                 export MB_PROFILE_CONF="$2"; shift 2 ;;
    --profiles-file=*) export MB_PROFILE_CONF="${1#*=}"; shift ;;
    --)          shift; while [[ $# -gt 0 ]]; do TOKENS+=("$1"); shift; done ;;
    -*)          err "Unknown option: '$1'."; echo >&2; usage; exit 2 ;;
    *)           TOKENS+=("$1"); shift ;;
  esac
done

# Validate numeric tunables.
for n in OS_RESERVE; do
  if ! [[ "${!n}" =~ ^[0-9]+$ ]]; then err "${n} must be a non-negative integer (got '${!n}')."; exit 2; fi
done
if [[ -n "${RAM_OVERRIDE}" && ! "${RAM_OVERRIDE}" =~ ^[0-9]+$ ]]; then
  err "--ram must be a non-negative integer in MiB (got '${RAM_OVERRIDE}')."; exit 2
fi

PROFILE_CONF="$(mb_profile_conf)"

# ===========================================================================
# Build the service -> MiB map once (shared by every mode).
# ===========================================================================
declare -A SVC_MIB=()
declare -a SVC_ORDER=()
while IFS=$'\t' read -r _svc _mib; do
  [[ -n "${_svc}" ]] || continue
  SVC_MIB["${_svc}"]="${_mib}"
  SVC_ORDER+=("${_svc}")
done < <(mb_build_service_map)

# Resolve total RAM (override wins; else detect; may be empty on a non-Pi box).
detect_ram() {
  if [[ -n "${RAM_OVERRIDE}" ]]; then echo "${RAM_OVERRIDE}"; return 0; fi
  mb_meminfo_total_mib
}

# Human helper: right-pad / format a MiB number as "1234 MB".
mb_fmt() { printf '%s MB' "$1"; }

# ===========================================================================
# MODE: --table — the memory-limit source-of-truth (every service + its cap)
# ===========================================================================
if [[ "${MODE}" == "table" ]]; then
  printf '%sMemory-limit source of truth%s — read live from the compose files\n\n' "${C_BOLD}" "${C_OFF}"
  printf '  %-18s %10s\n' "SERVICE" "LIMIT"
  printf '  %-18s %10s\n' "------------------" "----------"
  total=0; missing=0
  for s in "${SVC_ORDER[@]}"; do
    m="${SVC_MIB[${s}]}"
    if [[ -z "${m}" ]]; then
      printf '  %-18s %10s\n' "${s}" "MISSING"; missing=$((missing+1))
    else
      printf '  %-18s %10s\n' "${s}" "$(mb_fmt "${m}")"; total=$((total+m))
    fi
  done
  printf '  %-18s %10s\n' "------------------" "----------"
  printf '  %-18s %10s\n' "(sum, all)" "$(mb_fmt "${total}")"
  echo
  if (( missing > 0 )); then
    printf '%s%d service(s) have NO memory limit%s — add one (see infra-conventions).\n' \
      "${C_RED}" "${missing}" "${C_OFF}"
    exit 1
  fi
  printf 'All %d services declare a memory limit.\n' "${#SVC_ORDER[@]}"
  exit 0
fi

# ===========================================================================
# Footprint of one profile/list (used by --list and the header). Echoes
# "<used_mib> <missing_count>" for the flattened tokens. Unknown tokens are
# counted as missing here (so --list never errors); compute mode reports them.
# ===========================================================================
profile_footprint() {
  local used=0 miss=0 e label val mib
  while IFS= read -r e; do
    [[ -n "${e}" ]] || continue
    if [[ "${e}" == *=* ]]; then
      val="${e#*=}"; mib="$(mb_literal_mib "${val}" 2>/dev/null || true)"
      if [[ -n "${mib}" ]]; then used=$((used+mib)); else miss=$((miss+1)); fi
    elif [[ -n "${SVC_MIB[${e}]+x}" ]]; then
      mib="${SVC_MIB[${e}]}"
      if [[ -n "${mib}" ]]; then used=$((used+mib)); else miss=$((miss+1)); fi
    else
      miss=$((miss+1))
    fi
  done < <(mb_flatten "${PROFILE_CONF}" "$@")
  echo "${used} ${miss}"
}

# ===========================================================================
# MODE: --list (also the default when no tokens are given)
# ===========================================================================
if [[ "${MODE}" == "list" || ( "${MODE}" == "compute" && ${#TOKENS[@]} -eq 0 ) ]]; then
  RAM="$(detect_ram)"
  if [[ -n "${RAM}" && "${RAM}" =~ ^[0-9]+$ ]]; then
    SAFE="$(mb_safe_mib "${RAM}" "${OS_RESERVE}")"
    printf '%sBoot profiles%s — RAM %s, OS reserve %s, safe budget %s\n\n' \
      "${C_BOLD}" "${C_OFF}" "$(mb_fmt "${RAM}")" "$(mb_fmt "${OS_RESERVE}")" "$(mb_fmt "${SAFE}")"
  else
    SAFE=""
    printf '%sBoot profiles%s (pass --ram MiB for a verdict; RAM not detected here)\n\n' \
      "${C_BOLD}" "${C_OFF}"
  fi
  printf '  %-12s %10s   %s\n' "PROFILE" "FOOTPRINT" "VERDICT"
  printf '  %-12s %10s   %s\n' "------------" "----------" "-------"
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    read -r used miss < <(profile_footprint "${p}")
    if [[ -n "${SAFE}" ]]; then
      v="$(mb_overall_verdict "${miss}" "${used}" "${SAFE}")"
      case "${v}" in
        PASS) col="${C_GREEN}";; WARN) col="${C_YELLOW}";; *) col="${C_RED}";;
      esac
      printf '  %-12s %10s   %s%s%s\n' "${p}" "$(mb_fmt "${used}")" "${col}" "${v}" "${C_OFF}"
    else
      printf '  %-12s %10s\n' "${p}" "$(mb_fmt "${used}")"
    fi
  done < <(mb_profile_names "${PROFILE_CONF}")
  echo
  printf 'Check a profile before bringing it up:  ./scripts/mem-budget.sh <profile>\n'
  printf 'See every service limit:               ./scripts/mem-budget.sh --table\n'
  exit 0
fi

# ===========================================================================
# MODE: compute — resolve the requested tokens, sum, verdict
# ===========================================================================
# Flatten profiles/services/literals into a concrete, de-duplicated list.
declare -a FLAT=()
mapfile -t FLAT < <(mb_flatten "${PROFILE_CONF}" "${TOKENS[@]}")

if (( ${#FLAT[@]} == 0 )); then
  err "Nothing to budget — '${TOKENS[*]}' resolved to no services."
  exit 2
fi

# Classify each entry: literal allowance, known service, missing-limit, unknown.
declare -a ROWS=()           # "label<TAB>mib_or_MISSING<TAB>kind"
declare -a UNKNOWN=()
USED=0; MISSING=0
for e in "${FLAT[@]}"; do
  if [[ "${e}" == *=* ]]; then
    label="${e%%=*}"; val="${e#*=}"
    if mib="$(mb_literal_mib "${val}" 2>/dev/null)" && [[ -n "${mib}" ]]; then
      ROWS+=("${label} (project)"$'\t'"${mib}"$'\t'"literal"); USED=$((USED+mib))
    else
      UNKNOWN+=("${e}")
    fi
  elif [[ -n "${SVC_MIB[${e}]+x}" ]]; then
    mib="${SVC_MIB[${e}]}"
    if [[ -n "${mib}" ]]; then
      ROWS+=("${e}"$'\t'"${mib}"$'\t'"service"); USED=$((USED+mib))
    else
      ROWS+=("${e}"$'\t'"MISSING"$'\t'"missing"); MISSING=$((MISSING+1))
    fi
  else
    UNKNOWN+=("${e}")
  fi
done

# Unknown tokens are a usage error — list them and the valid choices.
if (( ${#UNKNOWN[@]} )); then
  err "Unknown service/profile/allowance: ${UNKNOWN[*]}"
  {
    printf '  Known profiles: %s\n' "$(mb_profile_names "${PROFILE_CONF}" | paste -sd' ' -)"
    printf '  Known services: %s\n' "${SVC_ORDER[*]}"
    printf '  Or a literal allowance like  myproject=512\n'
  } >&2
  exit 2
fi

# Resolve RAM (required to give a verdict).
RAM="$(detect_ram)"
if [[ -z "${RAM}" || ! "${RAM}" =~ ^[0-9]+$ ]]; then
  err "Could not detect total RAM (/proc/meminfo unavailable here). Pass --ram MiB (e.g. --ram 8192)."
  exit 2
fi
SAFE="$(mb_safe_mib "${RAM}" "${OS_RESERVE}")"
HEADROOM=$(( SAFE - USED ))
VERDICT="$(mb_overall_verdict "${MISSING}" "${USED}" "${SAFE}")"

# --- Render ----------------------------------------------------------------
if (( ! QUIET )); then
  printf '%spi-system memory budget%s — read-only\n' "${C_BOLD}" "${C_OFF}"
  printf 'Requested    : %s\n' "${TOKENS[*]}"
  printf 'Profiles file: %s\n\n' "${PROFILE_CONF}"

  printf '%s== Per-service breakdown ==%s\n' "${C_CYAN}" "${C_OFF}"
  printf '  %-26s %10s\n' "SERVICE / ALLOWANCE" "MEMORY"
  printf '  %-26s %10s\n' "--------------------------" "----------"
  for r in "${ROWS[@]}"; do
    IFS=$'\t' read -r rlabel rmib rkind <<< "${r}"
    if [[ "${rkind}" == "missing" ]]; then
      printf '  %-26s %s%10s%s\n' "${rlabel}" "${C_RED}" "MISSING" "${C_OFF}"
    else
      printf '  %-26s %10s\n' "${rlabel}" "$(mb_fmt "${rmib}")"
    fi
  done
  printf '  %-26s %10s\n' "--------------------------" "----------"
  printf '  %-26s %10s\n\n' "TOTAL requested" "$(mb_fmt "${USED}")"

  printf '%s== Budget ==%s\n' "${C_CYAN}" "${C_OFF}"
  printf '  %-26s %10s\n' "Total RAM" "$(mb_fmt "${RAM}")"
  printf '  %-26s %10s\n' "OS / Docker reserve" "$(mb_fmt "${OS_RESERVE}")"
  printf '  %-26s %10s\n' "Safe budget (RAM - reserve)" "$(mb_fmt "${SAFE}")"
  printf '  %-26s %10s\n' "Requested total" "$(mb_fmt "${USED}")"
  if (( HEADROOM >= 0 )); then
    printf '  %-26s %10s\n\n' "Headroom left" "$(mb_fmt "${HEADROOM}")"
  else
    printf '  %-26s %s%10s%s\n\n' "Over budget by" "${C_RED}" "$(mb_fmt "$(( -HEADROOM ))")" "${C_OFF}"
  fi

  if (( MISSING > 0 )); then
    printf '%s%d selected service(s) have NO memory limit%s — an unbounded container can\n' \
      "${C_RED}" "${MISSING}" "${C_OFF}"
    printf 'starve the others, so the budget cannot be guaranteed. Add a limit (see\n'
    printf 'infra-conventions) and re-run.\n\n'
  fi
fi

case "${VERDICT}" in
  PASS)
    printf '%sVERDICT: PASS%s — fits in the safe budget (%s of %s used, %s free).\n' \
      "${C_GREEN}${C_BOLD}" "${C_OFF}" "$(mb_fmt "${USED}")" "$(mb_fmt "${SAFE}")" "$(mb_fmt "${HEADROOM}")"
    exit 0 ;;
  WARN)
    printf '%sVERDICT: WARN%s — fits, but uses %s of the %s safe budget (over %d%%). Leave\n' \
      "${C_YELLOW}${C_BOLD}" "${C_OFF}" "$(mb_fmt "${USED}")" "$(mb_fmt "${SAFE}")" "${MB_WARN_PCT}"
    printf 'room for the page cache, builds and any project you host. Consider 16 GB.\n'
    exit 0 ;;
  *)
    if (( MISSING > 0 )); then
      printf '%sVERDICT: FAIL%s — a selected service has no memory limit (see above).\n' \
        "${C_RED}${C_BOLD}" "${C_OFF}" >&2
    else
      printf '%sVERDICT: FAIL%s — needs %s but only %s is safe to use (over by %s).\n' \
        "${C_RED}${C_BOLD}" "${C_OFF}" "$(mb_fmt "${USED}")" "$(mb_fmt "${SAFE}")" "$(mb_fmt "$(( USED - SAFE ))")" >&2
      printf 'Run fewer services at once, pick a lighter profile, or use a larger Pi.\n' >&2
    fi
    exit 1 ;;
esac
