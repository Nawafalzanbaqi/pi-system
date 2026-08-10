#!/usr/bin/env bash
# ===========================================================================
# pi-system — PREFLIGHT readiness check  (READ-ONLY)
# ---------------------------------------------------------------------------
# Run this on the Pi BEFORE you bring anything up. It diagnoses the most likely
# first-run failures early and prints a clear PASS / WARN / FAIL report with a
# final verdict. It NEVER changes state: it does not start or stop a single
# container, write a secret, pull an image, or touch a volume — it only reads,
# parses and queries (read-only `docker` verbs only).
#
# What it checks (scoped to the services you intend to run — see --services):
#   HOST      Docker installed + daemon up; Docker Compose v2; CPU is arm64;
#             enough free disk on the SSD; total/available RAM.
#   BOOT      Whether root is on an SSD vs an SD/eMMC card (write-wear risk).
#   ENV       .env exists; every REQUIRED variable for the scoped services is
#             present and non-empty; secret STRENGTH via scripts/check-secrets.sh
#             (the platform-wide empty/weak/Redis/n8n-key/backup-key criticals).
#   COMPOSE   Every scoped compose merge parses (`docker compose config`);
#             obvious host-port and container-name collisions.
#   IMAGES    Each pinned image tag still EXISTS in the registry and advertises
#             linux/arm64. Network failures here are a WARN (offline), not a FAIL.
#   NET/VOL   Which named networks/volumes already exist vs will be created.
#
# Usage:
#     ./scripts/preflight.sh [options]
#
#   --services LIST   Comma/space list of what you intend to run; scopes the
#                     ENV/COMPOSE/IMAGE checks. Use "core" for proxy+management.
#                     Known: proxy management postgres mysql mongo redis
#                            pgadmin adminer mongo-express auth automation
#                            dashboard cache backup
#                     (Or set PREFLIGHT_SERVICES in the environment.)
#   --all             Check every component the platform can run.
#   -q, --quiet       Print only FAILs and the final summary/verdict.
#   --disk-threshold GB   Recommended free-disk threshold (WARN below). Default 10.
#   --ram-threshold  MB   Recommended total-RAM threshold (WARN below). Default 3500.
#   -h, --help        Show this help and exit.
#
# Default scope (no flags): the always-on core (proxy + management) PLUS any
# components currently running (auto-detected, best-effort, via docker ps).
#
# Exit code: 0 if there are no FAILs (warnings are allowed), 1 otherwise.
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Load the pure-logic library (classifiers, parsers, registry, seams) ---
LIB="${SCRIPT_DIR}/lib/preflight-lib.sh"
if [[ ! -f "${LIB}" ]]; then
  printf '\033[0;31m[error]\033[0m Missing required library: %s\n' "${LIB}" >&2
  exit 1
fi
# shellcheck source=scripts/lib/preflight-lib.sh
source "${LIB}"

ENV_FILE="${PROJECT_ROOT}/.env"
CHECK_SECRETS="${SCRIPT_DIR}/check-secrets.sh"

# --- Tunables (overridable via flags) --------------------------------------
DISK_WARN_GB=10          # WARN if free disk < this
DISK_FAIL_GB=2           # FAIL if free disk < this (hard floor)
RAM_WARN_MB=3500         # WARN if total RAM < this (a 4 GB Pi reports ~3800)
RAM_FAIL_MB=1500         # FAIL if total RAM < this (hard floor)

QUIET=0
WANT_ALL=0
SERVICES_ARG="${PREFLIGHT_SERVICES:-}"

# --- Colours (off when not a TTY, or NO_COLOR set) -------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_CYAN=$'\033[1;36m';  C_BOLD=$'\033[1m';      C_OFF=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_BOLD=''; C_OFF=''
fi

log()  { printf '%s[preflight]%s %s\n' "${C_GREEN}" "${C_OFF}" "$*"; }
err()  { printf '%s[error]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }

usage() {
  cat >&2 <<EOF
Usage: ./scripts/preflight.sh [options]

  --services LIST       Comma/space list of what you intend to run; scopes the
                        ENV/COMPOSE/IMAGE checks. "core" = proxy+management.
                        Known: ${PF_ALL_COMPONENTS[*]}
                        (Or set PREFLIGHT_SERVICES in the environment.)
  --all                 Check every component the platform can run.
  -q, --quiet           Print only FAILs and the final summary/verdict.
  --disk-threshold GB   Recommended free-disk threshold, WARN below (default ${DISK_WARN_GB}).
  --ram-threshold  MB   Recommended total-RAM threshold, WARN below (default ${RAM_WARN_MB}).
  -h, --help            Show this help and exit.

Default scope (no flags): the always-on core (proxy + management) PLUS any
components currently running (auto-detected via 'docker ps').

READ-ONLY: never starts/stops services, writes secrets, pulls images or mutates
state. Exit code: 0 if there are no FAILs (warnings allowed), 1 otherwise.
EOF
}

# --- Parse arguments -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--quiet) QUIET=1; shift ;;
    --all)      WANT_ALL=1; shift ;;
    --services) [[ $# -ge 2 ]] || { err "--services requires a value."; exit 1; }
                SERVICES_ARG="${SERVICES_ARG:+${SERVICES_ARG} }$2"; shift 2 ;;
    --services=*) SERVICES_ARG="${SERVICES_ARG:+${SERVICES_ARG} }${1#*=}"; shift ;;
    --disk-threshold) [[ $# -ge 2 ]] || { err "--disk-threshold requires a value."; exit 1; }
                DISK_WARN_GB="$2"; shift 2 ;;
    --disk-threshold=*) DISK_WARN_GB="${1#*=}"; shift ;;
    --ram-threshold) [[ $# -ge 2 ]] || { err "--ram-threshold requires a value."; exit 1; }
                RAM_WARN_MB="$2"; shift 2 ;;
    --ram-threshold=*) RAM_WARN_MB="${1#*=}"; shift ;;
    -h|--help)  usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; echo; usage; exit 1 ;;
  esac
done

for n in DISK_WARN_GB RAM_WARN_MB; do
  if ! [[ "${!n}" =~ ^[0-9]+$ ]]; then
    err "${n} must be a non-negative integer (got '${!n}')."; exit 1
  fi
done

# ===========================================================================
# Result accumulation + rendering
# ===========================================================================
pass_n=0; warn_n=0; fail_n=0
CUR_SECTION=""

section() {
  CUR_SECTION="$1"
  (( QUIET )) && return 0
  printf '\n%s== %s ==%s\n' "${C_CYAN}" "$1" "${C_OFF}"
}

# record STATUS MESSAGE  — count it and print it (quiet shows only FAIL).
record() {
  local status="$1"; shift
  local msg="$*"
  case "${status}" in
    PASS) pass_n=$((pass_n+1)) ;;
    WARN) warn_n=$((warn_n+1)) ;;
    FAIL) fail_n=$((fail_n+1)) ;;
  esac
  if (( QUIET )); then
    [[ "${status}" == "FAIL" ]] || return 0
    printf '  %s✗ FAIL%s  [%s] %s\n' "${C_RED}" "${C_OFF}" "${CUR_SECTION}" "${msg}"
    return 0
  fi
  case "${status}" in
    PASS) printf '  %s✓ PASS%s  %s\n' "${C_GREEN}"  "${C_OFF}" "${msg}" ;;
    WARN) printf '  %s! WARN%s  %s\n' "${C_YELLOW}" "${C_OFF}" "${msg}" ;;
    FAIL) printf '  %s✗ FAIL%s  %s\n' "${C_RED}"    "${C_OFF}" "${msg}" ;;
  esac
}

# note — informational only (no verdict, suppressed in quiet).
note()   { (( QUIET )) && return 0; printf '         %s\n' "$*"; }
# detail — extra lines under a result; printed in BOTH modes (matters on FAIL).
detail() { printf '         %s\n' "$*"; }

# --- Small helpers ---------------------------------------------------------
# Deduplicate the lines on stdin, preserving first-seen order.
dedup_keep_order() { awk '!seen[$0]++'; }

# ===========================================================================
# Resolve the SCOPE (which components the checks apply to)
# ===========================================================================
DOCKER_PRESENT=0; DOCKER_OK=0
if pf_have_cmd docker; then
  DOCKER_PRESENT=1
  if pf_docker_running && pf_compose_available; then DOCKER_OK=1; fi
fi

# Project name + the running components (best-effort) — needed for default scope.
PROJECT_NAME="$(pf_env_value COMPOSE_PROJECT_NAME "${ENV_FILE}")"; PROJECT_NAME="${PROJECT_NAME:-pi-system}"

running_components() {
  (( DOCKER_OK )) || return 0
  local name suffix comp
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    suffix="${name#"${PROJECT_NAME}_"}"
    [[ "${suffix}" == "${name}" ]] && continue   # not one of ours
    comp="$(pf_container_to_component "${suffix}")"
    [[ -n "${comp}" ]] && echo "${comp}"
  done < <(pf_running_container_names) | sort -u
}

declare -a SCOPE=()
if (( WANT_ALL )); then
  SCOPE=("${PF_ALL_COMPONENTS[@]}")
elif [[ -n "${SERVICES_ARG}" ]]; then
  # Split on commas and whitespace, expand "core", validate, dedup.
  read -r -a _tokens <<< "${SERVICES_ARG//,/ }"
  declare -a _expanded=()
  for t in "${_tokens[@]}"; do
    [[ -z "${t}" ]] && continue
    if [[ "${t}" == "core" ]]; then
      _expanded+=("${PF_CORE_COMPONENTS[@]}")
    elif pf_is_component "${t}"; then
      _expanded+=("${t}")
    else
      err "Unknown service '${t}'. Known: core ${PF_ALL_COMPONENTS[*]}"
      exit 1
    fi
  done
  mapfile -t SCOPE < <(printf '%s\n' "${_expanded[@]}" | dedup_keep_order)
else
  # Default: core + anything currently running.
  mapfile -t SCOPE < <( { printf '%s\n' "${PF_CORE_COMPONENTS[@]}"; running_components; } | dedup_keep_order )
fi

# ===========================================================================
# Header
# ===========================================================================
if (( ! QUIET )); then
  printf '%spi-system preflight%s — read-only readiness check\n' "${C_BOLD}" "${C_OFF}"
  printf 'Project root : %s\n' "${PROJECT_ROOT}"
  printf 'Scope        : %s\n' "${SCOPE[*]}"
  printf 'Docker       : %s\n' \
    "$( (( DOCKER_OK )) && echo 'CLI + daemon + compose v2 OK' || { (( DOCKER_PRESENT )) && echo 'CLI present, daemon/compose NOT ready' || echo 'not installed'; } )"
fi

# ===========================================================================
# HOST
# ===========================================================================
section "Host"
if (( DOCKER_PRESENT )); then
  record PASS "Docker CLI found: $(pf_docker --version 2>/dev/null | head -1)"
  if pf_docker_running; then
    record PASS "Docker daemon is running."
  else
    record FAIL "Docker daemon not reachable — start it (sudo systemctl start docker) and ensure your user is in the 'docker' group."
  fi
  if pf_compose_available; then
    record PASS "Docker Compose v2 available: $(pf_docker compose version --short 2>/dev/null)"
  else
    record FAIL "Docker Compose v2 plugin missing — install docker-compose-plugin."
  fi
else
  record FAIL "Docker CLI not found on PATH — install Docker before bringing the stack up (curl -fsSL https://get.docker.com | sh)."
fi

# Container LOG ROTATION — Docker's default json-file driver is UNBOUNDED, so a
# chatty or crash-looping container can slowly fill the SSD. Verify the daemon
# has a default size cap (read-only: `docker info` for the effective driver +
# daemon.json for its log-opts). A missing cap is a WARN — a slow-burn risk that
# needs a root daemon restart to fix, never a launch blocker. Skipped (like the
# other Docker-dependent checks) when the daemon is not reachable here.
if (( DOCKER_OK )); then
  LOG_DRIVER="$(pf_docker_log_driver)"
  DAEMON_JSON="$(pf_daemon_json_path)"
  LOG_MAXSIZE="$(pf_daemon_log_opt "${DAEMON_JSON}" max-size)"
  LOG_MAXFILE="$(pf_daemon_log_opt "${DAEMON_JSON}" max-file)"
  LOGROT="$(pf_logrotate_verdict "${LOG_DRIVER}" "${LOG_MAXSIZE}" "${LOG_MAXFILE}")"
  record "${LOGROT%%|*}" "Container log rotation — ${LOGROT#*|}."
  if [[ "${LOGROT%%|*}" == "WARN" ]]; then
    detail "Apply once (root): sudo cp infrastructure/docker-daemon.json.example /etc/docker/daemon.json && sudo systemctl restart docker"
    detail "Existing containers keep their old log config until recreated (next 'up')."
  fi
else
  record WARN "Skipped Docker log-rotation check — Docker daemon not available (re-run on the Pi)."
fi

ARCH="$(pf_uname_m)"
if [[ "$(pf_arch_verdict "${ARCH}")" == "PASS" ]]; then
  record PASS "CPU architecture is ${ARCH} (arm64 — matches the pinned linux/arm64 images)."
else
  record WARN "CPU architecture is ${ARCH:-unknown}, not arm64 — the images are pinned for linux/arm64 (fine on a dev box, but the Pi must be arm64)."
fi

AVAIL_KB="$(pf_disk_avail_kb "${PROJECT_ROOT}")"
if [[ -z "${AVAIL_KB}" || ! "${AVAIL_KB}" =~ ^[0-9]+$ ]]; then
  record WARN "Could not determine free disk space for ${PROJECT_ROOT}."
else
  AVAIL_GB=$(( AVAIL_KB / 1024 / 1024 ))
  case "$(pf_classify_min "${AVAIL_KB}" $((DISK_WARN_GB*1024*1024)) $((DISK_FAIL_GB*1024*1024)))" in
    PASS) record PASS "Free disk where the project lives: ${AVAIL_GB} GB (>= ${DISK_WARN_GB} GB)." ;;
    WARN) record WARN "Free disk: ${AVAIL_GB} GB — below the recommended ${DISK_WARN_GB} GB; images + volumes may not fit comfortably." ;;
    FAIL) record FAIL "Free disk: ${AVAIL_GB} GB — below the hard floor ${DISK_FAIL_GB} GB; pulling images will likely fail." ;;
  esac
fi

MEM_TOTAL="$(pf_mem_total_mb)"
if [[ -z "${MEM_TOTAL}" || ! "${MEM_TOTAL}" =~ ^[0-9]+$ ]]; then
  record WARN "Could not read total RAM (/proc/meminfo unavailable here)."
else
  case "$(pf_classify_min "${MEM_TOTAL}" "${RAM_WARN_MB}" "${RAM_FAIL_MB}")" in
    PASS) record PASS "Total RAM: ${MEM_TOTAL} MB (>= ${RAM_WARN_MB} MB)." ;;
    WARN) record WARN "Total RAM: ${MEM_TOTAL} MB — below the recommended ${RAM_WARN_MB} MB; run heavy services (Keycloak, MySQL) one at a time." ;;
    FAIL) record FAIL "Total RAM: ${MEM_TOTAL} MB — below the hard floor ${RAM_FAIL_MB} MB; the stack will struggle." ;;
  esac
  MEM_AVAIL="$(pf_mem_avail_mb)"
  [[ "${MEM_AVAIL}" =~ ^[0-9]+$ ]] && note "Available RAM right now: ${MEM_AVAIL} MB."
fi

# ===========================================================================
# BOOT MEDIA
# ===========================================================================
section "Boot media"
ROOT_SRC="$(pf_root_source)"
case "$(pf_sdcard_verdict "${ROOT_SRC}")" in
  PASS) record PASS "Root filesystem is on ${ROOT_SRC} (looks like an SSD/HDD — good for a 24/7 server)." ;;
  WARN) record WARN "Root filesystem is on ${ROOT_SRC} (looks like an SD/eMMC card) — write-wear risk; the platform is designed to run from an SSD." ;;
  *)    record WARN "Could not classify the root device (${ROOT_SRC:-unknown}); confirm you are booting from the SSD, not an SD card." ;;
esac

# ===========================================================================
# ENV (.env presence + required vars + secret strength)
# ===========================================================================
section "Environment (.env)"
if [[ ! -f "${ENV_FILE}" ]]; then
  record FAIL ".env not found at the project root. Create it:  ./scripts/generate-secrets.sh   (or ./scripts/setup.sh)"
else
  record PASS ".env is present."

  for comp in "${SCOPE[@]}"; do
    reqs="${PF_REQVARS[${comp}]:-}"
    [[ -z "${reqs}" ]] && continue
    # shellcheck disable=SC2086  # intentional word-split of the var list
    mapfile -t miss < <(pf_missing_required "${ENV_FILE}" ${reqs})
    if (( ${#miss[@]} )); then
      record FAIL "[${comp}] missing or empty required .env var(s): ${miss[*]}"
    else
      record PASS "[${comp}] all required .env vars are present and non-empty."
    fi
  done

  # Secret STRENGTH — delegate to the existing auditor; do not re-implement it.
  if [[ -f "${CHECK_SECRETS}" ]]; then
    set +e
    CS_OUT="$(bash "${CHECK_SECRETS}" 2>&1)"
    CS_RC=$?
    set -e
    CS_SUMMARY="$(printf '%s\n' "${CS_OUT}" | grep -E 'Summary:' | tail -n1 | sed -E 's/^.*Summary: //')"
    case "$(pf_classify_secret_audit "${CS_RC}" "${CS_OUT}")" in
      FAIL)
        record FAIL "Secret audit (check-secrets.sh) found CRITICAL problem(s)${CS_SUMMARY:+ — ${CS_SUMMARY}}."
        while IFS= read -r l; do [[ -n "${l}" ]] && detail "${l#  }"; done \
          < <(printf '%s\n' "${CS_OUT}" | grep -E '✗' || true)
        detail "These are platform-wide secret floors (empty Redis/n8n-key/backup-key, weak/short)."
        detail "Fix with: ./scripts/generate-secrets.sh --force   then re-run." ;;
      WARN)
        record WARN "Secret audit passed with warning(s)${CS_SUMMARY:+ — ${CS_SUMMARY}}. Review: ./scripts/check-secrets.sh" ;;
      PASS)
        record PASS "Secret audit passed${CS_SUMMARY:+ — ${CS_SUMMARY}} (no values shown)." ;;
    esac
  else
    record WARN "scripts/check-secrets.sh not found — secret strength not audited."
  fi
fi

# ===========================================================================
# Build the unique set of scoped compose files (used by COMPOSE + IMAGES + VOL)
# ===========================================================================
declare -a SCOPED_FILES=()
for comp in "${SCOPE[@]}"; do
  # shellcheck disable=SC2206  # intentional word-split of the file list
  files=(${PF_COMPOSE[${comp}]:-})
  SCOPED_FILES+=("${files[@]}")
done
mapfile -t SCOPED_FILES < <(printf '%s\n' "${SCOPED_FILES[@]}" | dedup_keep_order)

# ===========================================================================
# COMPOSE (parse validation + collision detection)
# ===========================================================================
section "Compose files"

# Each scoped file should at least exist.
missing_files=0
for f in "${SCOPED_FILES[@]}"; do
  if [[ ! -f "${PROJECT_ROOT}/${f}" ]]; then
    record FAIL "Compose file missing: ${f}"
    missing_files=1
  fi
done
(( missing_files )) || record PASS "All ${#SCOPED_FILES[@]} scoped compose file(s) are present."

# Parse-validate each scoped component's merge (needs Docker Compose).
if (( DOCKER_OK )); then
  declare -A seen_merge=()
  for comp in "${SCOPE[@]}"; do
    files="${PF_COMPOSE[${comp}]}"
    profile="${PF_PROFILE[${comp}]:-}"
    key="${files}|${profile}"
    [[ -n "${seen_merge[${key}]:-}" ]] && continue
    seen_merge[${key}]=1

    args=(--env-file "${ENV_FILE}" --project-directory "${PROJECT_ROOT}")
    # shellcheck disable=SC2086
    for f in ${files}; do args+=(-f "${f}"); done
    [[ -n "${profile}" ]] && args+=(--profile "${profile}")

    if pf_compose_config "${args[@]}"; then
      record PASS "[${comp}] compose config parses${profile:+ (profile ${profile})}."
    else
      record FAIL "[${comp}] compose config FAILED to parse."
      set +e
      ERRD="$(pf_docker compose "${args[@]}" config 2>&1 >/dev/null)"
      set -e
      while IFS= read -r l; do [[ -n "${l}" ]] && detail "${l}"; done < <(printf '%s\n' "${ERRD}" | head -5)
    fi
  done
else
  record WARN "Skipped compose parse validation — Docker Compose not available (re-run on the Pi)."
fi

# Collision detection is PURE (no Docker needed) — always run it.
mapfile -t DUP_PORTS < <(
  for f in "${SCOPED_FILES[@]}"; do pf_extract_host_ports "${PROJECT_ROOT}/${f}"; done | pf_find_duplicates
)
if (( ${#DUP_PORTS[@]} )); then
  record FAIL "Host-port collision(s) across scoped compose files: ${DUP_PORTS[*]}"
else
  record PASS "No host-port collisions across the scoped compose files."
fi

mapfile -t DUP_NAMES < <(
  for f in "${SCOPED_FILES[@]}"; do pf_extract_container_names "${PROJECT_ROOT}/${f}"; done | pf_find_duplicates
)
if (( ${#DUP_NAMES[@]} )); then
  record FAIL "Container-name collision(s) across scoped compose files: ${DUP_NAMES[*]}"
else
  record PASS "No container-name collisions across the scoped compose files."
fi

# ===========================================================================
# IMAGES (registry existence + arm64), best-effort
# ===========================================================================
section "Images (registry + arm64)"
mapfile -t IMAGES < <(
  for f in "${SCOPED_FILES[@]}"; do pf_extract_images "${PROJECT_ROOT}/${f}"; done | sort -u
)
if (( ${#IMAGES[@]} == 0 )); then
  note "No registry images in scope (only locally-built or none)."
elif (( ! DOCKER_PRESENT )); then
  record WARN "Skipped image checks — the docker CLI is needed to query the registry (re-run on the Pi / when online)."
else
  offline_n=0
  for img in "${IMAGES[@]}"; do
    set +e
    verdict="$(pf_check_image "${img}")"
    set -e
    status="${verdict%%|*}"; reason="${verdict#*|}"
    record "${status}" "${img} — ${reason}."
    [[ "${status}" == "WARN" ]] && offline_n=$((offline_n+1))
  done
  (( offline_n > 0 )) && note "Could not verify ${offline_n} image(s) — re-run online. (Offline is a warning, never a failure.)"
fi

# ===========================================================================
# NETWORKS & VOLUMES (informational: exist vs will-be-created)
# ===========================================================================
section "Networks & volumes"
INTERNAL_NET="$(pf_env_value INTERNAL_NETWORK_NAME "${ENV_FILE}")"; INTERNAL_NET="${INTERNAL_NET:-pi_internal}"
PROXY_NET="$(pf_env_value PROXY_NETWORK_NAME "${ENV_FILE}")"; PROXY_NET="${PROXY_NET:-pi_proxy}"

if (( DOCKER_OK )); then
  mapfile -t EXISTING_NETS < <(pf_existing_networks)
  net_reused=0; net_create=0
  for n in "${INTERNAL_NET}" "${PROXY_NET}"; do
    if printf '%s\n' "${EXISTING_NETS[@]}" | grep -qx -- "${n}"; then
      note "network ${n}: already exists (will be reused)."; net_reused=$((net_reused+1))
    else
      note "network ${n}: will be created on first 'up'."; net_create=$((net_create+1))
    fi
  done
  record PASS "Networks: ${net_reused} present, ${net_create} to create (internal=${INTERNAL_NET}, proxy=${PROXY_NET})."

  mapfile -t DECL_VOLS < <(
    for f in "${SCOPED_FILES[@]}"; do pf_extract_volumes "${PROJECT_ROOT}/${f}"; done | sort -u
  )
  if (( ${#DECL_VOLS[@]} )); then
    mapfile -t EXISTING_VOLS < <(pf_existing_volumes)
    vol_reused=0; vol_create=0
    for v in "${DECL_VOLS[@]}"; do
      full="${PROJECT_NAME}_${v}"
      if printf '%s\n' "${EXISTING_VOLS[@]}" | grep -qx -- "${full}"; then
        note "volume ${full}: already exists (data will be reused)."; vol_reused=$((vol_reused+1))
      else
        note "volume ${full}: will be created on first 'up'."; vol_create=$((vol_create+1))
      fi
    done
    record PASS "Volumes: ${vol_reused} present, ${vol_create} to create (scoped)."
  else
    note "No named volumes declared in the scoped files."
  fi
else
  record WARN "Skipped network/volume inventory — Docker not available (re-run on the Pi)."
fi

# ===========================================================================
# Summary + verdict
# ===========================================================================
echo
printf '%s== Summary ==%s\n' "${C_CYAN}" "${C_OFF}"
printf '  %s%d PASS%s   %s%d WARN%s   %s%d FAIL%s\n' \
  "${C_GREEN}" "${pass_n}" "${C_OFF}" \
  "${C_YELLOW}" "${warn_n}" "${C_OFF}" \
  "${C_RED}" "${fail_n}" "${C_OFF}"
echo

if (( fail_n > 0 )); then
  printf '%sVERDICT: NOT READY%s — %d check(s) failed. Fix the FAILs above before any `up`.\n' \
    "${C_RED}${C_BOLD}" "${C_OFF}" "${fail_n}" >&2
  exit 1
elif (( warn_n > 0 )); then
  printf '%sVERDICT: READY (with %d warning(s))%s — review the WARNs; none block bring-up.\n' \
    "${C_YELLOW}${C_BOLD}" "${warn_n}" "${C_OFF}"
  exit 0
else
  printf '%sVERDICT: READY%s — all checks passed. Safe to proceed with bring-up.\n' \
    "${C_GREEN}${C_BOLD}" "${C_OFF}"
  exit 0
fi
