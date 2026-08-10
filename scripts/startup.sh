#!/usr/bin/env bash
# ===========================================================================
# pi-system — STAGED, VERIFIED bring-up
# ---------------------------------------------------------------------------
# Brings the platform up one DEPENDENCY-ORDERED LAYER at a time and VERIFIES
# each layer is genuinely healthy before allowing the next, so a first-run
# failure is ISOLATED to the stage that caused it instead of drowning you in a
# tangle of everything-at-once errors. This is the recommended way to start the
# platform during the final manual session.
#
# Stage order (each verified before the next):
#   1 networks    base shared networks (internal + proxy)
#   2 proxy       reverse proxy (Caddy)
#   3 management  Portainer, Uptime Kuma, Watchtower
#   4 dashboard   Homepage
#   --- then ONLY the optional stages your profile / flags select: ---
#   5 databases   the chosen engine(s)            6 db-admin   admin UI(s)
#   7 cache       package cache                   8 auth       Keycloak + db
#   9 automation  n8n + db                       10 projects   generated apps
#
# It NEVER forces the whole stack up: you choose the scope with a boot PROFILE
# (infrastructure/boot-profiles.conf) and/or explicit flags. By default it runs
# the read-only preflight + memory-budget checks first and refuses to proceed if
# either FAILs (override with --skip-checks). Re-running is safe and idempotent:
# stages that are already healthy are detected and left untouched, so bringing up
# a superset profile only starts the MISSING stages.
#
# Usage:
#     ./scripts/startup.sh [options]
#
#   --profile NAME        Boot profile to bring up (core, dev, auth, automation,
#                         ...). Default: core. Profiles nest (every one builds on
#                         core); see infrastructure/boot-profiles.conf.
#   --services LIST       Extra services/profiles (comma/space). Unioned with
#                         --profile. e.g. --services "postgres redis".
#   --stages LIST         Bring up these stages explicitly (networks always runs
#                         first). e.g. --stages "databases,auth".
#   --with-projects       Also bring up generated projects under services/ (the
#                         projects stage; off by default so deploys are opt-in).
#   --projects LIST       Limit the projects stage to these project names.
#   --skip-checks         Skip BOTH preflight and mem-budget (default: run them).
#   --skip-preflight      Skip only preflight.
#   --skip-mem-budget     Skip only the memory-budget check.
#   --timeout SEC         Per-stage health timeout (default 120).
#   --interval SEC        Base poll interval / backoff base (default 3).
#   --max-interval SEC    Backoff cap (default 15).
#   --crashloop-restarts N  Restart-count growth that means "crash loop" => FAIL
#                         (default 3; 0 disables the guard).
#   --ram MiB             Passed to mem-budget for planning (e.g. 8192/16384).
#   --os-reserve MiB      Passed to mem-budget (RAM held back for OS/Docker).
#   --dry-run             Print the staged PLAN (order, services, verify method)
#                         and exit. No Docker, no checks, nothing started.
#   -y, --yes             Non-interactive (assume yes; never prompt).
#   -q, --quiet           Less chatter (still prints PASS/FAIL + the summary).
#   -h, --help            Show this help and exit.
#
# Exit code: 0 if every selected stage came up healthy, 1 otherwise (with the
# failing container's last log lines printed to speed diagnosis).
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Load the pure-logic library (stage registry, planners, verify, seams) -
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

# --- Tunables (overridable via flags) --------------------------------------
TIMEOUT=120          # per-stage health timeout, seconds
INTERVAL=3           # base poll interval / backoff base, seconds
MAX_INTERVAL=15      # backoff cap, seconds
CRASHLOOP=3          # restart-count growth that means crash loop (0 disables)
RAM_OVERRIDE=""
OS_RESERVE=""

RUN_PREFLIGHT=1
RUN_MEM_BUDGET=1
WITH_PROJECTS=0
PROJECTS_FILTER=""
DRY_RUN=0
ASSUME_YES=0
QUIET=0

declare -a TOKENS=()         # profile / service tokens
declare -a STAGE_TOKENS=()   # explicit --stages

# --- Colours (off when not a TTY, or NO_COLOR set) -------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_CYAN=$'\033[1;36m';  C_BOLD=$'\033[1m';      C_OFF=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_BOLD=''; C_OFF=''
fi
log()  { printf '%s[startup]%s %s\n' "${C_GREEN}" "${C_OFF}" "$*"; }
warn() { printf '%s[warn]%s %s\n' "${C_YELLOW}" "${C_OFF}" "$*" >&2; }
err()  { printf '%s[error]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }
note() { (( QUIET )) && return 0; printf '         %s\n' "$*"; }

usage() { sed -n '2,/^# ===/p' "${BASH_SOURCE[0]}" | sed '1d;$d; s/^# \{0,1\}//'; }

# --- Parse arguments -------------------------------------------------------
needval() { [[ $# -ge 2 ]] || { err "$1 requires a value."; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)        needval "$@"; TOKENS+=("$2"); shift 2 ;;
    --profile=*)      TOKENS+=("${1#*=}"); shift ;;
    --services)       needval "$@"; read -r -a _t <<< "${2//,/ }"; TOKENS+=("${_t[@]}"); shift 2 ;;
    --services=*)     read -r -a _t <<< "${1#*=}"; _t=("${_t[@]//,/ }"); read -r -a _t <<< "${_t[*]}"; TOKENS+=("${_t[@]}"); shift ;;
    --stages)         needval "$@"; read -r -a _t <<< "${2//,/ }"; STAGE_TOKENS+=("${_t[@]}"); shift 2 ;;
    --stages=*)       read -r -a _t <<< "${1#*=}"; read -r -a _t <<< "${_t[*]//,/ }"; STAGE_TOKENS+=("${_t[@]}"); shift ;;
    --with-projects)  WITH_PROJECTS=1; shift ;;
    --projects)       needval "$@"; PROJECTS_FILTER="${PROJECTS_FILTER:+${PROJECTS_FILTER} }${2//,/ }"; WITH_PROJECTS=1; shift 2 ;;
    --projects=*)     PROJECTS_FILTER="${PROJECTS_FILTER:+${PROJECTS_FILTER} }${1#*=}"; PROJECTS_FILTER="${PROJECTS_FILTER//,/ }"; WITH_PROJECTS=1; shift ;;
    --skip-checks)    RUN_PREFLIGHT=0; RUN_MEM_BUDGET=0; shift ;;
    --skip-preflight) RUN_PREFLIGHT=0; shift ;;
    --skip-mem-budget) RUN_MEM_BUDGET=0; shift ;;
    --timeout)        needval "$@"; TIMEOUT="$2"; shift 2 ;;
    --timeout=*)      TIMEOUT="${1#*=}"; shift ;;
    --interval)       needval "$@"; INTERVAL="$2"; shift 2 ;;
    --interval=*)     INTERVAL="${1#*=}"; shift ;;
    --max-interval)   needval "$@"; MAX_INTERVAL="$2"; shift 2 ;;
    --max-interval=*) MAX_INTERVAL="${1#*=}"; shift ;;
    --crashloop-restarts) needval "$@"; CRASHLOOP="$2"; shift 2 ;;
    --crashloop-restarts=*) CRASHLOOP="${1#*=}"; shift ;;
    --ram)            needval "$@"; RAM_OVERRIDE="$2"; shift 2 ;;
    --ram=*)          RAM_OVERRIDE="${1#*=}"; shift ;;
    --os-reserve)     needval "$@"; OS_RESERVE="$2"; shift 2 ;;
    --os-reserve=*)   OS_RESERVE="${1#*=}"; shift ;;
    --dry-run)        DRY_RUN=1; shift ;;
    -y|--yes)         ASSUME_YES=1; shift ;;
    -q|--quiet)       QUIET=1; shift ;;
    -h|--help)        usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; echo >&2; usage >&2; exit 2 ;;
  esac
done

for n in TIMEOUT INTERVAL MAX_INTERVAL CRASHLOOP; do
  [[ "${!n}" =~ ^[0-9]+$ ]] || { err "${n} must be a non-negative integer (got '${!n}')."; exit 2; }
done
(( INTERVAL >= 1 )) || { err "--interval must be >= 1."; exit 2; }
(( MAX_INTERVAL >= INTERVAL )) || { err "--max-interval must be >= --interval."; exit 2; }

# ===========================================================================
# Build the staged PLAN (which stages, with which selected services)
# ===========================================================================
# Default scope: the core profile (the minimal always-on set). Never the whole
# stack — optional stages come only from the profile/flags the operator picks.
if (( ${#TOKENS[@]} == 0 && ${#STAGE_TOKENS[@]} == 0 )); then
  TOKENS=(core)
fi

declare -A SEL=()    # stage -> space-separated selected services
declare -A INCL=()   # stage -> 1 if the stage is in the plan
INCL[networks]=1     # the networks stage is always first

# (a) Expand profile/service tokens -> flat services -> per-stage selections.
if (( ${#TOKENS[@]} )); then
  mapfile -t FLAT < <(su_expand_tokens "${PROFILE_CONF}" "${TOKENS[@]}")
  while IFS=$'\t' read -r _stage _svcs; do
    [[ -n "${_stage}" ]] || continue
    INCL[${_stage}]=1
    SEL[${_stage}]="${SEL[${_stage}]:-}${SEL[${_stage}]:+ }${_svcs}"
  done < <(su_plan_from_services "${FLAT[@]}")
fi

# (b) Explicit --stages: include the stage and (for service-bearing stages) its
#     full default member set.
for st in "${STAGE_TOKENS[@]}"; do
  [[ -n "${st}" ]] || continue
  if [[ "${st}" == "projects" ]]; then WITH_PROJECTS=1; continue; fi
  if ! su_is_stage "${st}"; then
    err "Unknown stage '${st}'. Known: ${SU_STAGE_ORDER[*]}"; exit 2
  fi
  INCL[${st}]=1
  defaults="$(su_stage_default_services "${st}")"
  [[ -n "${defaults}" ]] && SEL[${st}]="${SEL[${st}]:-}${SEL[${st}]:+ }${defaults}"
done

# (c) Generated projects are opt-in.
(( WITH_PROJECTS )) && INCL[projects]=1

# De-duplicate each stage's selected services, preserving registry order.
for st in "${!SEL[@]}"; do
  SEL[${st}]="$(printf '%s\n' ${SEL[${st}]} | su_dedup_keep_order | paste -sd' ' -)"
done

# The ordered list of stages we will actually run.
declare -a PLAN=()
for st in "${SU_STAGE_ORDER[@]}"; do
  [[ -n "${INCL[${st}]:-}" ]] && PLAN+=("${st}")
done

# All selected services across the plan (for scoping preflight + mem-budget).
declare -a ALL_SERVICES=()
for st in "${PLAN[@]}"; do
  [[ -n "${SEL[${st}]:-}" ]] && read -r -a _s <<< "${SEL[${st}]}" && ALL_SERVICES+=("${_s[@]}")
done

# --- Describe how a service is verified (for the plan printout) -------------
verify_method() {
  case "$1" in
    postgres|mysql|mongo|redis|keycloak-db|n8n-db) echo "Docker healthcheck" ;;
    *) echo "readiness probe (running + not crash-looping)" ;;
  esac
}

print_plan() {
  printf '%spi-system staged bring-up%s — plan\n' "${C_BOLD}" "${C_OFF}"
  printf 'Project root : %s\n' "${PROJECT_ROOT}"
  printf 'Scope tokens : %s\n' "${TOKENS[*]:-(none)}${STAGE_TOKENS:+  +stages: ${STAGE_TOKENS[*]}}"
  printf 'Per-stage    : timeout %ss, base interval %ss (cap %ss), crash-loop after %s restarts\n\n' \
    "${TIMEOUT}" "${INTERVAL}" "${MAX_INTERVAL}" "${CRASHLOOP}"
  local i=0 st svc
  for st in "${PLAN[@]}"; do
    i=$((i+1))
    printf '  %s%2d. %-10s%s %s\n' "${C_CYAN}" "${i}" "${st}" "${C_OFF}" "${SU_STAGE_DESC[${st}]}"
    if [[ "${st}" == "networks" ]]; then
      note "ensure: internal + proxy networks exist"
    elif [[ "${st}" == "projects" ]]; then
      local plist; plist="$(su_discover_projects | paste -sd' ' - 2>/dev/null || true)"
      [[ -n "${PROJECTS_FILTER}" ]] && plist="${PROJECTS_FILTER}"
      note "deploy: ${plist:-<none discovered>}"
    else
      for svc in ${SEL[${st}]:-}; do
        note "$(printf '%-14s verify: %s' "${svc}" "$(verify_method "${svc}")")"
      done
    fi
  done
  echo
}

# ===========================================================================
# Dry run: print the plan and stop. No Docker, no checks, nothing started.
# ===========================================================================
if (( DRY_RUN )); then
  print_plan
  log "Dry run — nothing was started. Drop --dry-run to bring the platform up."
  exit 0
fi

# ===========================================================================
# Preconditions
# ===========================================================================
if [[ ! -f "${ENV_FILE}" ]]; then
  err ".env not found at the project root. Create it:  ./scripts/setup.sh   (then ./scripts/generate-secrets.sh)"
  exit 1
fi
if ! su_have_cmd docker; then
  err "Docker CLI not found on PATH. Install Docker, then re-run."
  exit 1
fi
if ! su_docker_running; then
  err "Docker daemon not reachable. Start it (sudo systemctl start docker) and ensure your user is in the 'docker' group."
  exit 1
fi
if ! su_compose_available; then
  err "Docker Compose v2 plugin not available. Install docker-compose-plugin, then re-run."
  exit 1
fi

# ===========================================================================
# Header + plan
# ===========================================================================
(( QUIET )) || print_plan

# ===========================================================================
# Pre-flight gates (read-only) — refuse to proceed on FAIL unless skipped.
# ===========================================================================
# Build the preflight component scope from the selected services.
declare -a PF_COMPONENTS=()
for s in "${ALL_SERVICES[@]:-}"; do
  c="$(su_preflight_component "${s}")"
  [[ -n "${c}" ]] && PF_COMPONENTS+=("${c}")
done
mapfile -t PF_COMPONENTS < <(printf '%s\n' "${PF_COMPONENTS[@]:-}" | grep -v '^$' | su_dedup_keep_order || true)

if (( RUN_PREFLIGHT )); then
  log "Running read-only preflight check${PF_COMPONENTS:+ (scope: ${PF_COMPONENTS[*]})} ..."
  pf_args=()
  (( ${#PF_COMPONENTS[@]} )) && pf_args=(--services "${PF_COMPONENTS[*]}")
  if su_run_preflight "${pf_args[@]}"; then
    log "Preflight: READY."
  else
    err "Preflight reported FAILs — refusing to bring services up. Fix them, or re-run with --skip-preflight (or --skip-checks)."
    exit 1
  fi
else
  warn "Skipping preflight (--skip-preflight/--skip-checks). You own the risk."
fi

if (( RUN_MEM_BUDGET )); then
  # Budget exactly what we will start. Prefer the operator's profile tokens (so
  # the report reads naturally); fall back to the concrete service list.
  declare -a MB_TOKENS=()
  if (( ${#TOKENS[@]} )); then MB_TOKENS=("${TOKENS[@]}"); else MB_TOKENS=("${ALL_SERVICES[@]:-}"); fi
  mapfile -t MB_TOKENS < <(printf '%s\n' "${MB_TOKENS[@]:-}" | grep -v '^$' || true)
  if (( ${#MB_TOKENS[@]} )); then
    mb_args=("${MB_TOKENS[@]}")
    [[ -n "${RAM_OVERRIDE}" ]] && mb_args+=(--ram "${RAM_OVERRIDE}")
    [[ -n "${OS_RESERVE}" ]] && mb_args+=(--os-reserve "${OS_RESERVE}")
    log "Running read-only memory-budget check (${MB_TOKENS[*]}) ..."
    if su_run_mem_budget "${mb_args[@]}"; then
      log "Memory budget: fits."
    else
      err "Memory budget FAILed — the selected scope would not fit safely in RAM. Pick a lighter profile, or re-run with --skip-mem-budget (or --skip-checks)."
      exit 1
    fi
  fi
else
  warn "Skipping memory-budget check (--skip-mem-budget/--skip-checks)."
fi

# Optional confirmation gate before any state change (skipped with -y / no TTY).
if (( ! ASSUME_YES )) && [[ -t 0 ]]; then
  printf '%sBring up %d stage(s): %s%s\n' "${C_BOLD}" "${#PLAN[@]}" "${PLAN[*]}" "${C_OFF}"
  read -r -p "Proceed? [y/N] " _ans
  case "${_ans}" in y|Y|yes|YES) : ;; *) log "Aborted by operator. Nothing was started."; exit 0 ;; esac
fi

# ===========================================================================
# Per-stage verification machinery
# ===========================================================================
declare -A BASELINE=()      # service/ref label -> restart count first observed
declare -a REFS=()          # current "label<TAB>id" pairs being probed
declare -a STAGE_FAIL_REFS=() # "label<TAB>id" pairs that FAILed this round
LAST_VERDICT="${SU_WAIT}"
declare -a CARGS=()         # the current stage's `docker compose` argv (post-"compose")

# Build CARGS for a normal (service-bearing) stage from the registry.
build_cargs() {
  local stage="$1"; shift
  CARGS=(--env-file "${ENV_FILE}" --project-directory "${PROJECT_ROOT}")
  local f p
  for f in ${SU_STAGE_COMPOSE[${stage}]}; do CARGS+=(-f "${f}"); done
  while IFS= read -r p; do [[ -n "${p}" ]] && CARGS+=(--profile "${p}"); done < <(su_profiles_for_services "$@")
}

# Resolver: emit "service<TAB>containerID" for each service in SVC_LIST (global).
declare -a SVC_LIST=()
resolve_services() {
  local svc id
  for svc in "${SVC_LIST[@]}"; do
    id="$(su_service_container_id "${svc}" "${CARGS[@]}")"
    printf '%s\t%s\n' "${svc}" "${id}"
  done
}

# Resolver: emit "shortID<TAB>containerID" for every container of the current
# project (PCARGS global) — generated projects can have several containers.
declare -a PCARGS=()
resolve_project() {
  local id
  while IFS= read -r id; do
    [[ -n "${id}" ]] && printf '%s\t%s\n' "${id:0:12}" "${id}"
  done < <(su_docker compose "${PCARGS[@]}" ps -q 2>/dev/null || true)
}

# Evaluate the current REFS array -> sets LAST_VERDICT + STAGE_FAIL_REFS.
evaluate_refs() {
  STAGE_FAIL_REFS=()
  local folded="${SU_READY}" ref label id parsed state restarting count health base v
  for ref in "${REFS[@]}"; do
    label="${ref%%$'\t'*}"; id="${ref#*$'\t'}"
    parsed="$(su_parse_inspect "$(su_inspect "${id}")")"
    IFS=$'\t' read -r state restarting count health <<< "${parsed}"
    base="${BASELINE[${label}]:-${count}}"
    v="$(su_probe_verdict "${health}" "${state}" "${restarting}" "${count}" "${base}" "${CRASHLOOP}")"
    [[ "${v}" == "${SU_FAIL}" ]] && STAGE_FAIL_REFS+=("${ref}")
    folded="$(su_worst "${folded}" "${v}")"
  done
  LAST_VERDICT="${folded}"
}

# Capture restart-count baselines for the current resolver so the crash-loop
# guard measures GROWTH from bring-up, not an absolute count.
capture_baselines() {
  local resolver="$1" ref label id count
  mapfile -t REFS < <("${resolver}")
  for ref in "${REFS[@]}"; do
    label="${ref%%$'\t'*}"; id="${ref#*$'\t'}"
    count="$(su_parse_inspect "$(su_inspect "${id}")" | cut -f3)"
    BASELINE[${label}]="${count:-0}"
  done
}

# Poll until the stage is READY / FAIL / times out.
#   $1 = resolver function name, $2 = stage label (for messages)
# Returns 0 READY, 1 FAIL, 2 TIMEOUT. Leaves STAGE_FAIL_REFS / REFS populated.
wait_for() {
  local resolver="$1" label="$2" attempt=1 elapsed=0 delay rem
  while true; do
    mapfile -t REFS < <("${resolver}")
    evaluate_refs
    case "${LAST_VERDICT}" in
      "${SU_READY}") return 0 ;;
      "${SU_FAIL}")  return 1 ;;
    esac
    if [[ "$(su_deadline_reached "${elapsed}" "${TIMEOUT}")" == "yes" ]]; then return 2; fi
    delay="$(su_backoff_delay "${attempt}" "${INTERVAL}" "${MAX_INTERVAL}")"
    rem=$(( TIMEOUT - elapsed )); (( delay > rem )) && delay="${rem}"; (( delay < 1 )) && delay=1
    note "[${label}] not ready yet — waiting ${delay}s (elapsed ${elapsed}/${TIMEOUT}s) ..."
    su_sleep "${delay}"; elapsed=$(( elapsed + delay )); attempt=$(( attempt + 1 ))
  done
}

# Dump the last log lines of every FAILed (or, on timeout, every) container.
dump_failure_logs() {
  local mode="$1" ref label id
  local -a targets=()
  if [[ "${mode}" == "all" ]]; then targets=("${REFS[@]}"); else targets=("${STAGE_FAIL_REFS[@]}"); fi
  for ref in "${targets[@]}"; do
    label="${ref%%$'\t'*}"; id="${ref#*$'\t'}"
    printf '%s    --- last logs: %s ---%s\n' "${C_YELLOW}" "${label}" "${C_OFF}" >&2
    if [[ -n "${id}" ]]; then
      while IFS= read -r l; do printf '    %s\n' "${l}" >&2; done < <(su_logs_tail "${id}" 40)
    else
      printf '    (no container was created — check the compose/up output above)\n' >&2
    fi
  done
}

# ===========================================================================
# Run one stage. Echoes a final PASS/FAIL line; returns 0 (ok) / 1 (failed).
# ===========================================================================
declare -a RESULTS=()    # "stage<TAB>STATUS" for the final summary

stage_result() { RESULTS+=("$1"$'\t'"$2"); }

run_networks() {
  local internal proxy isub psub
  internal="$(grep -E '^[[:space:]]*INTERNAL_NETWORK_NAME=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' )"; internal="${internal:-pi_internal}"
  proxy="$(grep -E '^[[:space:]]*PROXY_NETWORK_NAME=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' )"; proxy="${proxy:-pi_proxy}"
  isub="$(grep -E '^[[:space:]]*INTERNAL_SUBNET=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' )"; isub="${isub:-172.20.0.0/16}"
  psub="$(grep -E '^[[:space:]]*PROXY_SUBNET=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r' )"; psub="${psub:-172.21.0.0/16}"

  printf '\n%s== Stage: networks — %s ==%s\n' "${C_CYAN}" "${SU_STAGE_DESC[networks]}" "${C_OFF}"
  # DESIGN: the platform networks are Compose-MANAGED — declared WITH IPAM in
  # infrastructure/docker-compose.yml, which EVERY stage merges in as its first
  # -f file. The first `docker compose up` therefore creates pi_internal /
  # pi_proxy itself, with the correct subnet AND the com.docker.compose.* labels.
  # This stage must NOT create them: a bare `docker network create` makes an
  # UN-LABELLED twin that Compose then refuses to adopt ("network ... has
  # incorrect label com.docker.compose.network set to """), failing every
  # bring-up. So we do the inverse — REAP a conflicting orphan (an un-labelled
  # network of that name left by an older broken run) so Compose can recreate it
  # cleanly. Absent network => do nothing; Compose-owned => leave as-is.
  local n ok=1 proj attached
  for n in "${internal}" "${proxy}"; do
    if ! su_network_exists "${n}"; then
      note "network ${n}: absent — Compose will create it (subnet + labels) on first 'up'."
      continue
    fi
    # Is it Compose-owned? Compose stamps com.docker.compose.project on its
    # networks; a bare `docker network create` leaves that label empty.
    proj="$(su_docker network inspect "${n}" --format '{{index .Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
    if [[ -n "${proj}" ]]; then
      note "network ${n}: Compose-managed (project='${proj}') — left as-is."
      continue
    fi
    # Orphan (no Compose project label). Reap it ONLY if nothing is attached —
    # never tear a network out from under running containers.
    attached="$(su_docker network inspect "${n}" --format '{{len .Containers}}' 2>/dev/null || echo '?')"
    if [[ "${attached}" == "0" ]]; then
      if su_docker network rm "${n}" >/dev/null 2>&1; then
        note "network ${n}: removed stray un-labelled network so Compose can recreate it."
      else
        err "network ${n}: stray un-labelled network could not be removed."; ok=0
      fi
    else
      err "network ${n}: stray un-labelled network has ${attached} attached container(s); cannot auto-remove. Disconnect them, or run: docker network rm ${n}"; ok=0
    fi
  done
  if (( ok )); then
    printf '  %s✓ PASS%s  networks ready (internal=%s, proxy=%s) — owned by Compose (subnets %s / %s).\n' "${C_GREEN}" "${C_OFF}" "${internal}" "${proxy}" "${isub}" "${psub}"
    stage_result networks PASS; return 0
  fi
  printf '  %s✗ FAIL%s  a conflicting un-labelled network blocks Compose.\n' "${C_RED}" "${C_OFF}"
  stage_result networks FAIL; return 1
}

run_service_stage() {
  local stage="$1"; shift
  read -r -a SVC_LIST <<< "$*"
  build_cargs "${stage}" "${SVC_LIST[@]}"
  BASELINE=()

  printf '\n%s== Stage: %s — %s ==%s\n' "${C_CYAN}" "${stage}" "${SU_STAGE_DESC[${stage}]}" "${C_OFF}"
  note "services: ${SVC_LIST[*]}"

  # Idempotency: if every service is ALREADY healthy, don't touch it.
  mapfile -t REFS < <(resolve_services); evaluate_refs
  if [[ "${LAST_VERDICT}" == "${SU_READY}" ]]; then
    printf '  %s✓ PASS%s  already healthy — skipped (idempotent).\n' "${C_GREEN}" "${C_OFF}"
    stage_result "${stage}" SKIP; return 0
  fi

  log "Bringing up ${stage} (${SVC_LIST[*]}) ..."
  if ! su_docker compose "${CARGS[@]}" up -d "${SVC_LIST[@]}"; then
    printf '  %s✗ FAIL%s  `docker compose up` failed for stage %s.\n' "${C_RED}" "${C_OFF}" "${stage}"
    mapfile -t REFS < <(resolve_services); dump_failure_logs all
    stage_result "${stage}" FAIL; return 1
  fi

  capture_baselines resolve_services
  wait_for resolve_services "${stage}"; local rc=$?
  case "${rc}" in
    0) printf '  %s✓ PASS%s  %s is healthy.\n' "${C_GREEN}" "${C_OFF}" "${stage}"; stage_result "${stage}" PASS; return 0 ;;
    1) printf '  %s✗ FAIL%s  a %s container is unhealthy / crash-looping.\n' "${C_RED}" "${C_OFF}" "${stage}"
       dump_failure_logs fail; stage_result "${stage}" FAIL; return 1 ;;
    2) printf '  %s✗ FAIL%s  %s did not become healthy within %ss (timeout).\n' "${C_RED}" "${C_OFF}" "${stage}" "${TIMEOUT}"
       dump_failure_logs all; stage_result "${stage}" FAIL; return 1 ;;
  esac
}

run_projects() {
  printf '\n%s== Stage: projects — %s ==%s\n' "${C_CYAN}" "${SU_STAGE_DESC[projects]}" "${C_OFF}"
  local -a projects=()
  mapfile -t projects < <(su_discover_projects)
  if [[ -n "${PROJECTS_FILTER}" ]]; then
    local -a filtered=() p want
    for p in "${projects[@]}"; do
      for want in ${PROJECTS_FILTER}; do [[ "${p}" == "${want}" ]] && filtered+=("${p}"); done
    done
    projects=("${filtered[@]}")
  fi
  if (( ${#projects[@]} == 0 )); then
    note "no generated projects found under services/ — nothing to deploy."
    printf '  %s✓ PASS%s  projects stage: nothing to do.\n' "${C_GREEN}" "${C_OFF}"
    stage_result projects SKIP; return 0
  fi

  local p ok=1 frag rc
  for p in "${projects[@]}"; do
    note "project: ${p}"
    PCARGS=(--env-file "${ENV_FILE}" --project-directory "${PROJECT_ROOT}" -f "infrastructure/docker-compose.yml")
    PCARGS+=(-f "services/${p}/${p}.compose.yml")
    shopt -s nullglob
    for frag in "services/${p}/${p}".*.compose.yml; do PCARGS+=(-f "${frag}"); done
    shopt -u nullglob
    BASELINE=()
    log "Building and starting project '${p}' ..."
    if ! su_docker compose "${PCARGS[@]}" up -d --build; then
      printf '  %s✗ FAIL%s  `docker compose up` failed for project %s.\n' "${C_RED}" "${C_OFF}" "${p}"
      mapfile -t REFS < <(resolve_project); dump_failure_logs all; ok=0; continue
    fi
    capture_baselines resolve_project
    wait_for resolve_project "project:${p}"; rc=$?
    case "${rc}" in
      0) printf '  %s✓ PASS%s  project %s is healthy.\n' "${C_GREEN}" "${C_OFF}" "${p}" ;;
      1) printf '  %s✗ FAIL%s  project %s has an unhealthy container.\n' "${C_RED}" "${C_OFF}" "${p}"; dump_failure_logs fail; ok=0 ;;
      2) printf '  %s✗ FAIL%s  project %s timed out after %ss.\n' "${C_RED}" "${C_OFF}" "${p}" "${TIMEOUT}"; dump_failure_logs all; ok=0 ;;
    esac
  done
  if (( ok )); then stage_result projects PASS; return 0; fi
  stage_result projects FAIL; return 1
}

# ===========================================================================
# Drive the stages in order; HALT on the first failed stage.
# ===========================================================================
# The walk-and-halt-on-failure contract lives in the library (su_run_plan), so it
# is the SAME code the test harness verifies. Our oracle starts + verifies one
# stage and returns 0 (healthy) / non-zero (failed).
stage_oracle() {
  case "$1" in
    networks) run_networks ;;
    projects) run_projects ;;
    *)        run_service_stage "$1" "${SEL[$1]:-$(su_stage_default_services "$1")}" ;;
  esac
}
OVERALL=0
su_run_plan stage_oracle "${PLAN[@]}" || OVERALL=1

# ===========================================================================
# Summary
# ===========================================================================
echo
printf '%s== Summary ==%s\n' "${C_CYAN}" "${C_OFF}"
declare -A _ran=()
for r in "${RESULTS[@]}"; do
  s="${r%%$'\t'*}"; v="${r#*$'\t'}"; _ran[${s}]=1
  case "${v}" in
    PASS) printf '  %s✓ %-10s PASS%s\n' "${C_GREEN}" "${s}" "${C_OFF}" ;;
    SKIP) printf '  %s✓ %-10s PASS%s (already healthy / nothing to do)\n' "${C_GREEN}" "${s}" "${C_OFF}" ;;
    FAIL) printf '  %s✗ %-10s FAIL%s\n' "${C_RED}" "${s}" "${C_OFF}" ;;
  esac
done
# Stages we planned but never reached (because an earlier stage halted us).
for st in "${PLAN[@]}"; do
  [[ -n "${_ran[${st}]:-}" ]] || printf '  %s· %-10s SKIPPED%s (a prior stage failed)\n' "${C_YELLOW}" "${st}" "${C_OFF}"
done
echo

if (( OVERALL == 0 )); then
  DOMAIN="$(grep -E '^BASE_DOMAIN=' "${ENV_FILE}" 2>/dev/null | tail -n1 | cut -d= -f2- | tr -d '\r')"; DOMAIN="${DOMAIN:-localhost}"
  printf '%sVERDICT: UP%s — every selected stage is healthy.\n' "${C_GREEN}${C_BOLD}" "${C_OFF}"
  note "Reach the UIs via Caddy, e.g. https://home.${DOMAIN} / https://status.${DOMAIN} / https://portainer.${DOMAIN}"
  note "Take it down safely (data kept) with:  ./scripts/shutdown.sh"
  exit 0
else
  printf '%sVERDICT: HALTED%s — a stage failed verification (see its last logs above).\n' "${C_RED}${C_BOLD}" "${C_OFF}" >&2
  printf 'The failure is isolated to that stage; later stages were not started. Fix it,\n' >&2
  printf 'then re-run ./scripts/startup.sh — healthy stages are detected and skipped.\n' >&2
  exit 1
fi
