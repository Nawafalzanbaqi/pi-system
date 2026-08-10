#!/usr/bin/env bash
# ===========================================================================
# pi-system — SAFE, reverse-order shutdown
# ---------------------------------------------------------------------------
# The mirror image of scripts/startup.sh: it stops the platform one stage at a
# time in the REVERSE of the bring-up order (projects -> automation -> auth ->
# cache -> db-admin -> databases -> dashboard -> management -> proxy), so the
# things that DEPEND on others come down first.
#
# It is DATA-SAFE BY DESIGN. Like every per-service helper on the platform it
# uses a TARGETED `docker compose rm -sf <services>` (stop + remove only those
# containers) and DELIBERATELY NEVER runs `docker compose down` (which would tear
# down the shared networks and other stacks) and NEVER `down -v` / removes a
# named volume. All database / identity / workflow / cache / certificate data in
# the named volumes SURVIVES — bring it back with ./scripts/startup.sh.
#
# By default it stops EVERYTHING the platform can run (data kept). Scope it with
# the same selectors as startup.sh to take down just part of the stack.
#
# Usage:
#     ./scripts/shutdown.sh [options]
#
#   --profile NAME        Only stop the stages this boot profile covers.
#   --services LIST       Only stop the stages these services/profiles cover.
#   --stages LIST         Only stop these stages (e.g. "auth,automation").
#   --projects LIST       Limit the projects stage to these project names.
#   --keep-projects       Do NOT stop generated projects (services/<name>/).
#   --remove-networks     Also remove the shared internal/proxy networks AFTER
#                         everything is down (best-effort; skipped if anything is
#                         still attached). Off by default — the networks are
#                         cheap, shared, and harmless to leave in place.
#   -y, --yes             Non-interactive (assume yes; never prompt).
#   --dry-run             Print what WOULD be stopped and exit. Nothing changes.
#   -q, --quiet           Less chatter.
#   -h, --help            Show this help and exit.
#
# Exit code: 0 on success. Run from anywhere — paths resolve to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

LIB="${SCRIPT_DIR}/lib/startup-lib.sh"
if [[ ! -f "${LIB}" ]]; then
  printf '\033[0;31m[error]\033[0m Missing required library: %s\n' "${LIB}" >&2
  exit 1
fi
# shellcheck source=scripts/lib/startup-lib.sh
source "${LIB}"

export SU_PROJECT_ROOT="${PROJECT_ROOT}"
ENV_FILE="${PROJECT_ROOT}/.env"
PROFILE_CONF="${PROJECT_ROOT}/infrastructure/boot-profiles.conf"

# --- Colours ----------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_CYAN=$'\033[1;36m';  C_BOLD=$'\033[1m';      C_OFF=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_BOLD=''; C_OFF=''
fi
log()  { printf '%s[shutdown]%s %s\n' "${C_GREEN}" "${C_OFF}" "$*"; }
warn() { printf '%s[warn]%s %s\n' "${C_YELLOW}" "${C_OFF}" "$*" >&2; }
err()  { printf '%s[error]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }
note() { (( QUIET )) && return 0; printf '         %s\n' "$*"; }

usage() { sed -n '2,/^# ===/p' "${BASH_SOURCE[0]}" | sed '1d;$d; s/^# \{0,1\}//'; }

QUIET=0; DRY_RUN=0; ASSUME_YES=0; REMOVE_NETWORKS=0; KEEP_PROJECTS=0
PROJECTS_FILTER=""
declare -a TOKENS=() STAGE_TOKENS=()

needval() { [[ $# -ge 2 ]] || { err "$1 requires a value."; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)        needval "$@"; TOKENS+=("$2"); shift 2 ;;
    --profile=*)      TOKENS+=("${1#*=}"); shift ;;
    --services)       needval "$@"; read -r -a _t <<< "${2//,/ }"; TOKENS+=("${_t[@]}"); shift 2 ;;
    --services=*)     read -r -a _t <<< "${1#*=}"; read -r -a _t <<< "${_t[*]//,/ }"; TOKENS+=("${_t[@]}"); shift ;;
    --stages)         needval "$@"; read -r -a _t <<< "${2//,/ }"; STAGE_TOKENS+=("${_t[@]}"); shift 2 ;;
    --stages=*)       read -r -a _t <<< "${1#*=}"; read -r -a _t <<< "${_t[*]//,/ }"; STAGE_TOKENS+=("${_t[@]}"); shift ;;
    --projects)       needval "$@"; PROJECTS_FILTER="${PROJECTS_FILTER:+${PROJECTS_FILTER} }${2//,/ }"; shift 2 ;;
    --projects=*)     PROJECTS_FILTER="${PROJECTS_FILTER:+${PROJECTS_FILTER} }${1#*=}"; PROJECTS_FILTER="${PROJECTS_FILTER//,/ }"; shift ;;
    --keep-projects)  KEEP_PROJECTS=1; shift ;;
    --remove-networks) REMOVE_NETWORKS=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -q|--quiet)       QUIET=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; echo >&2; usage >&2; exit 2 ;;
  esac
done

# ===========================================================================
# Build the set of stages to stop (default: everything).
# ===========================================================================
declare -A INCL=()
if (( ${#TOKENS[@]} == 0 && ${#STAGE_TOKENS[@]} == 0 )); then
  # Default: every service-bearing stage + projects (the whole platform).
  for st in "${SU_STAGE_ORDER[@]}"; do [[ "${st}" == "networks" ]] || INCL[${st}]=1; done
else
  if (( ${#TOKENS[@]} )); then
    mapfile -t FLAT < <(su_expand_tokens "${PROFILE_CONF}" "${TOKENS[@]}")
    while IFS=$'\t' read -r _stage _svcs; do [[ -n "${_stage}" ]] && INCL[${_stage}]=1; done < <(su_plan_from_services "${FLAT[@]}")
  fi
  for st in "${STAGE_TOKENS[@]}"; do
    [[ -n "${st}" ]] || continue
    if [[ "${st}" == "networks" ]]; then REMOVE_NETWORKS=1; continue; fi
    su_is_stage "${st}" || { err "Unknown stage '${st}'. Known: ${SU_STAGE_ORDER[*]}"; exit 2; }
    INCL[${st}]=1
  done
fi
(( KEEP_PROJECTS )) && unset 'INCL[projects]'

# Reverse dependency order (mirror of the bring-up order).
declare -a REV=()
for (( i=${#SU_STAGE_ORDER[@]}-1; i>=0; i-- )); do
  st="${SU_STAGE_ORDER[$i]}"
  [[ "${st}" == "networks" ]] && continue
  [[ -n "${INCL[${st}]:-}" ]] && REV+=("${st}")
done

# --- Plan printout ----------------------------------------------------------
print_plan() {
  printf '%spi-system shutdown%s — reverse-order, data-safe\n' "${C_BOLD}" "${C_OFF}"
  printf 'Stop order   : %s%s\n' "${REV[*]:-(none)}" "$( (( REMOVE_NETWORKS )) && echo ' , then networks' )"
  note "method: targeted 'compose rm -sf' (NEVER 'down' / 'down -v'); all data volumes are kept."
}
print_plan
if (( DRY_RUN )); then
  echo; log "Dry run — nothing was stopped."
  exit 0
fi

# --- Preconditions ----------------------------------------------------------
if ! su_have_cmd docker || ! su_docker_running || ! su_compose_available; then
  err "Docker / Compose v2 not available — cannot stop containers."
  exit 1
fi
[[ -f "${ENV_FILE}" ]] || warn ".env not found — using compose defaults for names."

# --- Confirmation -----------------------------------------------------------
if (( ! ASSUME_YES )) && [[ -t 0 ]]; then
  printf '%sStop %d stage(s): %s%s (data volumes are kept)\n' "${C_BOLD}" "${#REV[@]}" "${REV[*]}" "${C_OFF}"
  read -r -p "Proceed? [y/N] " _ans
  case "${_ans}" in y|Y|yes|YES) : ;; *) log "Aborted. Nothing was stopped."; exit 0 ;; esac
fi

# ===========================================================================
# Stop each stage in reverse order with a TARGETED rm -sf (data preserved).
# ===========================================================================
ENVARGS=(--env-file "${ENV_FILE}" --project-directory "${PROJECT_ROOT}")
[[ -f "${ENV_FILE}" ]] || ENVARGS=(--project-directory "${PROJECT_ROOT}")

stop_service_stage() {
  local stage="$1"
  local -a svcs cargs profiles
  read -r -a svcs <<< "$(su_stage_default_services "${stage}")"
  cargs=("${ENVARGS[@]}")
  local f p
  for f in ${SU_STAGE_COMPOSE[${stage}]}; do cargs+=(-f "${f}"); done
  # Enable every profile any member needs, so profile-gated services are in scope.
  while IFS= read -r p; do [[ -n "${p}" ]] && cargs+=(--profile "${p}"); done < <(su_profiles_for_services "${svcs[@]}")
  printf '\n%s== Stopping: %s — %s ==%s\n' "${C_CYAN}" "${stage}" "${SU_STAGE_DESC[${stage}]}" "${C_OFF}"
  note "rm -sf ${svcs[*]}"
  # `rm -sf` on an absent/already-removed service is a harmless no-op.
  su_docker compose "${cargs[@]}" rm -sf "${svcs[@]}" 2>/dev/null || \
    warn "compose rm reported an issue for ${stage} (likely already stopped) — continuing."
  printf '  %s✓%s %s stopped (data kept).\n' "${C_GREEN}" "${C_OFF}" "${stage}"
}

stop_projects() {
  printf '\n%s== Stopping: projects — %s ==%s\n' "${C_CYAN}" "${SU_STAGE_DESC[projects]}" "${C_OFF}"
  local -a projects=()
  mapfile -t projects < <(su_discover_projects)
  if [[ -n "${PROJECTS_FILTER}" ]]; then
    local -a filtered=() p want
    for p in "${projects[@]}"; do
      for want in ${PROJECTS_FILTER}; do [[ "${p}" == "${want}" ]] && filtered+=("${p}"); done
    done
    projects=("${filtered[@]}")
  fi
  if (( ${#projects[@]} == 0 )); then note "no generated projects to stop."; return 0; fi
  local p frag pcargs
  for p in "${projects[@]}"; do
    pcargs=("${ENVARGS[@]}" -f "infrastructure/docker-compose.yml" -f "services/${p}/${p}.compose.yml")
    shopt -s nullglob
    for frag in "services/${p}/${p}".*.compose.yml; do pcargs+=(-f "${frag}"); done
    shopt -u nullglob
    note "project ${p}: rm -sf"
    su_docker compose "${pcargs[@]}" rm -sf 2>/dev/null || warn "compose rm issue for project ${p} — continuing."
    printf '  %s✓%s project %s stopped (data kept).\n' "${C_GREEN}" "${C_OFF}" "${p}"
  done
}

for st in "${REV[@]}"; do
  case "${st}" in
    projects) stop_projects ;;
    *)        stop_service_stage "${st}" ;;
  esac
done

# ===========================================================================
# Optionally remove the shared networks (only if nothing is still attached).
# ===========================================================================
if (( REMOVE_NETWORKS )); then
  printf '\n%s== Removing shared networks ==%s\n' "${C_CYAN}" "${C_OFF}"
  internal="$(grep -E '^[[:space:]]*INTERNAL_NETWORK_NAME=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r')"; internal="${internal:-pi_internal}"
  proxy="$(grep -E '^[[:space:]]*PROXY_NETWORK_NAME=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r')"; proxy="${proxy:-pi_proxy}"
  for n in "${proxy}" "${internal}"; do
    if su_network_exists "${n}"; then
      if su_docker network rm "${n}" >/dev/null 2>&1; then
        printf '  %s✓%s removed network %s.\n' "${C_GREEN}" "${C_OFF}" "${n}"
      else
        warn "network ${n} still has endpoints attached — left in place. Stop the remaining containers first."
      fi
    else
      note "network ${n}: already absent."
    fi
  done
fi

echo
printf '%sVERDICT: DOWN%s — selected stages stopped. All named data volumes were preserved.\n' "${C_GREEN}${C_BOLD}" "${C_OFF}"
note "Bring it back any time with:  ./scripts/startup.sh"
exit 0
