#!/usr/bin/env bash
# ===========================================================================
# pi-system — WHOLE-SYSTEM STATUS snapshot  (READ-ONLY)
# ---------------------------------------------------------------------------
# One view of the health of EVERYTHING, by AGGREGATING the sources that already
# exist — it does not invent its own probes:
#
#   * per-service container state, using the SAME staged-bring-up registry +
#     per-container probe logic as scripts/startup.sh (scripts/lib/startup-lib.sh
#     -> su_inspect / su_parse_inspect / su_probe_verdict), so "up / healthy /
#     broken" here means exactly what it means during bring-up;
#   * which optional / profile-gated services are currently OFF (so you can tell
#     "intentionally not running" from "broken");
#   * the base shared networks (present / absent);
#   * generated projects discovered under services/ and whether they are up;
#   * a one-line HOST health summary by calling scripts/health-monitor.sh in
#     quiet mode (temp / disk / memory) — never re-implemented here;
#   * a final overall VERDICT.
#
# It is STRICTLY READ-ONLY: read-only `docker` verbs only (inspect / ps / network
# inspect) and a read-only health probe. It never starts or stops a container,
# writes a file, pulls an image, or prints a secret. `scripts/pi status` calls it.
#
# Usage:
#     ./scripts/status.sh [-q|--quiet] [-h|--help]
#
#   -q, --quiet   Print only the host line + the final overall verdict.
#   -h, --help    Show this help and exit.
#
# Exit code: 0 when the system is UP or intentionally DOWN; 1 when DEGRADED
# (something that IS running is broken, or host health hard-FAILed). Run from
# anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Load the control library (reuses startup-lib's registry + probes) -----
export CTL_PROJECT_ROOT="${PROJECT_ROOT}"
export SU_PROJECT_ROOT="${PROJECT_ROOT}"
LIB="${SCRIPT_DIR}/lib/ctl-lib.sh"
if [[ ! -f "${LIB}" ]]; then
  printf '\033[0;31m[error]\033[0m Missing required library: %s\n' "${LIB}" >&2
  exit 2
fi
# shellcheck source=scripts/lib/ctl-lib.sh
source "${LIB}"

ENV_FILE="${PROJECT_ROOT}/.env"

# --- Colours (off when not a TTY, or NO_COLOR set) -------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_CYAN=$'\033[1;36m';  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi
err() { printf '%s[error]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }

usage() {
  cat >&2 <<EOF
Usage: ./scripts/status.sh [-q|--quiet] [-h|--help]

  -q, --quiet   Print only the host line + the final overall verdict.
  -h, --help    Show this help and exit.

READ-ONLY whole-system snapshot: per-service state, off-vs-broken, networks,
generated projects, a one-line host-health summary, and an overall verdict.
Exit: 0 when UP or intentionally DOWN, 1 when DEGRADED.
EOF
}

QUIET=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quiet) QUIET=1; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; echo >&2; usage; exit 2 ;;
  esac
done

say()     { (( QUIET )) || printf '%s\n' "$*"; }
section() { (( QUIET )) || printf '\n%s== %s ==%s\n' "${C_CYAN}" "$1" "${C_OFF}"; }

# --- Read a value from .env without executing it (mirrors the other tools) --
env_val() {
  local key="$1" line val
  [[ -f "${ENV_FILE}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "${ENV_FILE}" 2>/dev/null | tail -n1 || true)"
  [[ -n "${line}" ]] || return 0
  val="${line#*=}"; val="${val%$'\r'}"
  printf '%s' "${val}"
}

# --- Colour a status label by severity -------------------------------------
label_colored() {
  case "$1" in
    healthy|running)              printf '%s%s%s' "${C_GREEN}"  "$1" "${C_OFF}" ;;
    starting|restarting|waiting)  printf '%s%s%s' "${C_YELLOW}" "$1" "${C_OFF}" ;;
    unhealthy|exited|dead|paused) printf '%s%s%s' "${C_RED}"    "$1" "${C_OFF}" ;;
    absent)                       printf '%s%s%s' "${C_DIM}"    "off" "${C_OFF}" ;;
    *)                            printf '%s' "$1" ;;
  esac
}
mark_for() {
  case "$1" in
    READY) printf '%s✓%s' "${C_GREEN}"  "${C_OFF}" ;;
    WAIT)  printf '%s~%s' "${C_YELLOW}" "${C_OFF}" ;;
    FAIL)  printf '%s✗%s' "${C_RED}"    "${C_OFF}" ;;
    *)     printf '%s·%s' "${C_DIM}"    "${C_OFF}" ;;
  esac
}

# --- Build the read-only compose argv for one service in a stage ------------
svc_cargs() {
  local stage="$1" svc="$2" f p
  CARGS=(--project-directory "${PROJECT_ROOT}")
  [[ -f "${ENV_FILE}" ]] && CARGS=(--env-file "${ENV_FILE}" --project-directory "${PROJECT_ROOT}")
  for f in ${SU_STAGE_COMPOSE[${stage}]}; do CARGS+=(-f "${f}"); done
  while IFS= read -r p; do [[ -n "${p}" ]] && CARGS+=(--profile "${p}"); done < <(su_profiles_for_services "${svc}")
}

# ===========================================================================
# Header + Docker availability
# ===========================================================================
PROJECT_NAME="$(env_val COMPOSE_PROJECT_NAME)"; PROJECT_NAME="${PROJECT_NAME:-pi-system}"
DOMAIN="$(env_val BASE_DOMAIN)"; DOMAIN="${DOMAIN:-localhost}"

if (( ! QUIET )); then
  printf '%spi-system status%s — read-only whole-system snapshot\n' "${C_BOLD}" "${C_OFF}"
  printf 'Project      : %s\n' "${PROJECT_NAME}"
  printf 'Base domain  : %s\n' "${DOMAIN}"
fi

DOCKER_OK=0
if su_have_cmd docker && su_docker_running && su_compose_available; then DOCKER_OK=1; fi

# Running tallies, folded by ctl_status_tally (one tested counting rule).
BROKEN=0; UP=0; OFF=0; WAITING=0
declare -a OFF_OPTIONAL=()   # profile-gated services that are currently off

# ===========================================================================
# Per-stage container state (skips networks/projects — handled separately)
# ===========================================================================
if (( DOCKER_OK )); then
  for stage in "${SU_STAGE_ORDER[@]}"; do
    [[ "${stage}" == "networks" || "${stage}" == "projects" ]] && continue
    svcs="${SU_STAGE_SERVICES[${stage}]:-}"
    [[ -n "${svcs}" ]] || continue

    # Probe every member first so we can show a per-stage roll-up line.
    declare -a lines=(); stage_up=0 stage_total=0 stage_broken=0
    for svc in ${svcs}; do
      svc_cargs "${stage}" "${svc}"
      IFS=$'\t' read -r label verdict < <(ctl_probe_service "${svc}" "${CARGS[@]}")
      read -r BROKEN UP OFF WAITING < <(ctl_status_tally "${BROKEN}" "${UP}" "${OFF}" "${WAITING}" "${verdict}")
      stage_total=$((stage_total+1))
      [[ "${verdict}" == "READY" || "${verdict}" == "WAIT" ]] && stage_up=$((stage_up+1))
      [[ "${verdict}" == "FAIL" ]] && stage_broken=$((stage_broken+1))
      # Note optional (profile-gated) services that are off, for the off-vs-broken view.
      if [[ "${verdict}" == "ABSENT" && -n "${SU_SERVICE_PROFILE[${svc}]:-}" ]]; then
        OFF_OPTIONAL+=("${svc}")
      fi
      local_opt=""; [[ -n "${SU_SERVICE_PROFILE[${svc}]:-}" ]] && local_opt=" ${C_DIM}(optional)${C_OFF}"
      lines+=("$(printf '    %s %-14s %s%s' "$(mark_for "${verdict}")" "${svc}" "$(label_colored "${label}")" "${local_opt}")")
    done

    if (( ! QUIET )); then
      local_state="off"
      (( stage_up > 0 )) && local_state="${stage_up}/${stage_total} up"
      (( stage_broken > 0 )) && local_state="${local_state}, ${C_RED}${stage_broken} broken${C_OFF}"
      printf '  %s%-11s%s %s — %s\n' "${C_BOLD}" "${stage}" "${C_OFF}" "${SU_STAGE_DESC[${stage}]}" "${local_state}"
      printf '%s\n' "${lines[@]}"
    fi
  done
fi

# ===========================================================================
# Base networks
# ===========================================================================
INTERNAL_NET="$(env_val INTERNAL_NETWORK_NAME)"; INTERNAL_NET="${INTERNAL_NET:-pi_internal}"
PROXY_NET="$(env_val PROXY_NETWORK_NAME)"; PROXY_NET="${PROXY_NET:-pi_proxy}"
NET_OK=0
if (( DOCKER_OK )); then
  section "Networks"
  for n in "${INTERNAL_NET}" "${PROXY_NET}"; do
    if su_network_exists "${n}"; then
      say "  $(mark_for READY) ${n}: present"
      NET_OK=$((NET_OK+1))
    else
      say "  $(mark_for "") ${n}: ${C_DIM}absent${C_OFF}"
    fi
  done
fi

# ===========================================================================
# Generated projects (discovered under services/, distinct from platform dirs)
# ===========================================================================
declare -a PROJECTS=()
mapfile -t PROJECTS < <(su_discover_projects)
PROJ_UP=0; PROJ_TOTAL=${#PROJECTS[@]}
if (( DOCKER_OK )); then
  section "Generated projects"
  if (( PROJ_TOTAL == 0 )); then
    say "  ${C_DIM}none discovered under services/ (deploy with: scripts/pi up --with-projects)${C_OFF}"
  else
    for p in "${PROJECTS[@]}"; do
      pcargs=(--project-directory "${PROJECT_ROOT}" -f "infrastructure/docker-compose.yml" -f "services/${p}/${p}.compose.yml")
      [[ -f "${ENV_FILE}" ]] && pcargs=(--env-file "${ENV_FILE}" "${pcargs[@]}")
      shopt -s nullglob
      for frag in "services/${p}/${p}".*.compose.yml; do pcargs+=(-f "${frag}"); done
      shopt -u nullglob
      mapfile -t ids < <(su_docker compose "${pcargs[@]}" ps -q 2>/dev/null || true)
      if (( ${#ids[@]} == 0 )); then
        say "  $(mark_for "") ${p}: ${C_DIM}down${C_OFF}"
      else
        run_ok=0 run_bad=0
        for id in "${ids[@]}"; do
          [[ -n "${id}" ]] || continue
          IFS=$'\t' read -r st rs ct hl < <(su_parse_inspect "$(su_inspect "${id}")")
          v="$(su_probe_verdict "${hl}" "${st}" "${rs}" "${ct}" "${ct}" 0)"
          [[ "${v}" == "FAIL" ]] && run_bad=$((run_bad+1)) || run_ok=$((run_ok+1))
        done
        if (( run_bad > 0 )); then
          say "  $(mark_for FAIL) ${p}: ${run_ok} up, ${C_RED}${run_bad} broken${C_OFF}"
          BROKEN=$((BROKEN+1))
        else
          say "  $(mark_for READY) ${p}: ${run_ok} container(s) up"
          UP=$((UP+1)); PROJ_UP=$((PROJ_UP+1))
        fi
      fi
    done
  fi
fi

# ===========================================================================
# Off-vs-broken summary (so the operator knows what's intentionally not running)
# ===========================================================================
if (( DOCKER_OK )) && (( ${#OFF_OPTIONAL[@]} > 0 )); then
  section "Currently off (optional / profile-gated)"
  say "  ${C_DIM}$(printf '%s ' "${OFF_OPTIONAL[@]}")${C_OFF}"
  say "  ${C_DIM}these are not running on purpose — start them with a profile, e.g. scripts/pi up --profile dev${C_OFF}"
fi

# ===========================================================================
# Host hardware health — one line, by calling health-monitor in quiet mode
# ===========================================================================
section "Host health"
HOST_VERDICT="UNKNOWN"; HOST_LINE=""
set +e
HM_OUT="$(ctl_run_health -q 2>&1)"
set -e
HOST_VERDICT="$(ctl_health_verdict "${HM_OUT}")"
HOST_LINE="$(printf '%s\n' "${HM_OUT}" | grep -E 'VERDICT:' | head -n1 | sed -E 's/\x1b\[[0-9;]*m//g' || true)"
case "${HOST_VERDICT}" in
  PASS) say "  $(mark_for READY) ${HOST_LINE:-host healthy}" ;;
  WARN) say "  $(mark_for WAIT) ${HOST_LINE:-host warning}" ;;
  FAIL) say "  $(mark_for FAIL) ${HOST_LINE:-host failing}" ;;
  *)    say "  $(mark_for "") ${C_DIM}host health unknown (health-monitor unavailable here)${C_OFF}" ;;
esac

# ===========================================================================
# Overall verdict
# ===========================================================================
echo
if (( ! DOCKER_OK )); then
  printf '%sVERDICT: UNKNOWN%s — Docker / Compose v2 is not reachable here, so live container state could not be read. Run this on the Pi.\n' \
    "${C_YELLOW}${C_BOLD}" "${C_OFF}"
  # Host health alone can still flag a hard failure.
  [[ "${HOST_VERDICT}" == "FAIL" ]] && exit 1
  exit 0
fi

OVERALL="$(ctl_status_overall "${BROKEN}" "${UP}" "${HOST_VERDICT}")"
(( ! QUIET )) && printf '%sRunning: %d up%s' "${C_BOLD}" "${UP}" "${C_OFF}" && \
  printf '%s' " · ${WAITING} settling · ${OFF} off · " && \
  printf '%s%d broken%s\n' "$( ((BROKEN)) && echo "${C_RED}" || echo "${C_GREEN}")" "${BROKEN}" "${C_OFF}"

case "${OVERALL}" in
  UP)
    printf '%sVERDICT: UP%s — %d service group(s) running, none broken%s.\n' \
      "${C_GREEN}${C_BOLD}" "${C_OFF}" "${UP}" "$( [[ "${HOST_VERDICT}" == "WARN" ]] && echo " (host health: WARN — review above)" || true )"
    exit 0 ;;
  DOWN)
    printf '%sVERDICT: DOWN%s — nothing is running. Bring the core up with: scripts/pi up --profile core\n' \
      "${C_YELLOW}${C_BOLD}" "${C_OFF}"
    exit 0 ;;
  DEGRADED)
    printf '%sVERDICT: DEGRADED%s — %d running item(s) are broken%s. Inspect logs (docker logs / portainer) and re-run scripts/pi up to re-verify.\n' \
      "${C_RED}${C_BOLD}" "${C_OFF}" "${BROKEN}" "$( [[ "${HOST_VERDICT}" == "FAIL" ]] && echo ", and host health FAILed" || true )" >&2
    exit 1 ;;
esac
