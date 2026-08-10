#!/usr/bin/env bash
# ===========================================================================
# pi-system — host HEALTH MONITOR  (READ-ONLY)
# ---------------------------------------------------------------------------
# A lightweight, read-only probe of the PI HARDWARE itself — the slow-burn
# risks that uptime monitoring (Uptime Kuma) cannot see because they are about
# the host, not whether a container answers:
#
#   * CPU TEMPERATURE + throttling   — is the Pi cooking / has it throttled?
#   * DISK usage (root/SSD + Docker)  — is the SSD slowly filling with backups
#                                       or logs?
#   * LIVE MEMORY + swap + per-container memory — is something leaking, or
#                                       sitting right against its limit?
#
# It prints a PASS / WARN / FAIL report and a final verdict. With --status-dir
# (what the cron job uses) it also writes a machine-readable status file + an
# append log and, on WARN/FAIL, fires a SWAPPABLE notifier (default: just the
# status file + an alert file that Uptime Kuma or the operator can watch; an
# optional Uptime Kuma push and/or your own HEALTH_NOTIFY_CMD can be wired in
# WITHOUT committing any secret).
#
# It is intentionally LIGHTWEIGHT: a read-only shell probe + host cron + a
# status file. There is deliberately NO Grafana/Prometheus/agent — that does
# not belong on a constrained Pi. See docs/README.md "Resource monitoring".
#
# Recommended place in the operator flow:
#     ./scripts/preflight.sh        # pre-launch: is the host ready at all?
#     ./scripts/startup.sh ...      # bring-up: each layer verified healthy
#     ./scripts/health-monitor.sh   # ONGOING: is the running Pi still healthy?
#
# Usage:
#     ./scripts/health-monitor.sh [options]
#
#   -q, --quiet            Print only the final verdict line (+ any WARN/FAIL).
#   --status-dir DIR       Also write last-health.json + append health.log here,
#                          and (on WARN/FAIL) run the notifier. Default: none
#                          (pure stdout). Env: HEALTH_STATUS_DIR.
#   --docker-data DIR      Docker data-root to size for disk (default
#                          /var/lib/docker). Env: DOCKER_DATA_DIR.
#   --no-docker            Skip the per-container `docker stats` section.
#   --temp-warn N --temp-fail N      °C thresholds   (default 70 / 80)
#   --disk-warn N --disk-fail N      % full          (default 80 / 90)
#   --mem-warn  N --mem-fail  N      % RAM used      (default 85 / 95)
#   --swap-warn N --swap-fail N      % swap used     (default 50 / 80)
#   --ctr-warn  N --ctr-fail  N      % of a container's own limit (default 85 / 95)
#   -h, --help             Show this help and exit.
#
# Every threshold also reads an env var (HEALTH_TEMP_WARN, HEALTH_DISK_FAIL, …)
# so the cron job / .env can tune them without editing this script.
#
# READ-ONLY: never starts/stops a container, changes config, or prints a secret
# (it reads none). The only writes are its OWN status file + log under
# --status-dir (its product, like the backup status files) — never to the
# things it monitors.
#
# Exit code: 0 on PASS/WARN/SKIP, 1 on FAIL, 2 on a usage error.
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Load the pure-logic library (parsers, classifiers, seams) -------------
LIB="${SCRIPT_DIR}/lib/health-monitor-lib.sh"
if [[ ! -f "${LIB}" ]]; then
  printf '\033[0;31m[error]\033[0m Missing required library: %s\n' "${LIB}" >&2
  exit 2
fi
# shellcheck source=scripts/lib/health-monitor-lib.sh
source "${LIB}"

# ===========================================================================
# Optional tuning from the root .env — read WITHOUT executing it (mirrors the
# safe extraction in preflight). Only these operational keys are read; their
# values are NEVER printed (HEALTH_UPTIME_KUMA_PUSH_URL may carry a token). Any
# secret in .env is ignored. This is what lets the cron run — which does not
# source .env — still honour your thresholds and notifier config from one place.
# Final precedence: command-line flag > pre-set environment > .env > built-in default.
# ===========================================================================
ENV_FILE="${PROJECT_ROOT}/.env"
_env_val() {
  local key="$1" line val
  [[ -f "${ENV_FILE}" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}=" "${ENV_FILE}" 2>/dev/null | tail -n1 || true)"
  [[ -n "${line}" ]] || return 0
  val="${line#*=}"; val="${val%$'\r'}"                 # drop trailing CR (CRLF)
  val="${val#"${val%%[![:space:]]*}"}"                 # ltrim
  val="${val%"${val##*[![:space:]]}"}"                 # rtrim
  if   [[ "${val}" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
  elif [[ "${val}" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
  fi
  printf '%s' "${val}"
}
for _k in HEALTH_TEMP_WARN HEALTH_TEMP_FAIL HEALTH_DISK_WARN HEALTH_DISK_FAIL \
          HEALTH_MEM_WARN HEALTH_MEM_FAIL HEALTH_SWAP_WARN HEALTH_SWAP_FAIL \
          HEALTH_CTR_WARN HEALTH_CTR_FAIL HEALTH_STATUS_DIR DOCKER_DATA_DIR \
          HEALTH_UPTIME_KUMA_PUSH_URL HEALTH_NOTIFY_CMD BACKUP_DIR; do
  if [[ -z "${!_k:-}" ]]; then
    _v="$(_env_val "${_k}")"
    [[ -n "${_v}" ]] && export "${_k}=${_v}"
  fi
done
unset _k _v

# ===========================================================================
# Tunables — flag overrides env overrides default. (env name in the comment.)
# ===========================================================================
TEMP_WARN="${HEALTH_TEMP_WARN:-70}";  TEMP_FAIL="${HEALTH_TEMP_FAIL:-80}"   # °C
DISK_WARN="${HEALTH_DISK_WARN:-80}";  DISK_FAIL="${HEALTH_DISK_FAIL:-90}"   # % full
MEM_WARN="${HEALTH_MEM_WARN:-85}";    MEM_FAIL="${HEALTH_MEM_FAIL:-95}"     # % RAM used
SWAP_WARN="${HEALTH_SWAP_WARN:-50}";  SWAP_FAIL="${HEALTH_SWAP_FAIL:-80}"   # % swap used
CTR_WARN="${HEALTH_CTR_WARN:-85}";    CTR_FAIL="${HEALTH_CTR_FAIL:-95}"     # % of own limit

STATUS_DIR="${HEALTH_STATUS_DIR:-}"
DOCKER_DATA_DIR="${DOCKER_DATA_DIR:-/var/lib/docker}"
BACKUP_DIR_REL="${BACKUP_DIR:-./data/backups}"
KUMA_URL="${HEALTH_UPTIME_KUMA_PUSH_URL:-}"
NOTIFY_CMD="${HEALTH_NOTIFY_CMD:-}"
QUIET=0
DO_DOCKER=1

# --- Colours (off when not a TTY, or NO_COLOR set) -------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_CYAN=$'\033[1;36m';  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi
err()  { printf '%s[error]%s %s\n' "${C_RED}" "${C_OFF}" "$*" >&2; }

usage() {
  cat >&2 <<EOF
Usage: ./scripts/health-monitor.sh [options]

  -q, --quiet            Only the final verdict line (+ any WARN/FAIL detail).
  --status-dir DIR       Write last-health.json + append health.log here and,
                         on WARN/FAIL, fire the notifier. (env HEALTH_STATUS_DIR)
  --docker-data DIR      Docker data-root sized for disk (default ${DOCKER_DATA_DIR}).
  --no-docker            Skip the per-container docker stats section.
  --temp-warn/--temp-fail N   °C        (default ${TEMP_WARN}/${TEMP_FAIL})
  --disk-warn/--disk-fail N   % full    (default ${DISK_WARN}/${DISK_FAIL})
  --mem-warn/--mem-fail   N   % RAM     (default ${MEM_WARN}/${MEM_FAIL})
  --swap-warn/--swap-fail N   % swap    (default ${SWAP_WARN}/${SWAP_FAIL})
  --ctr-warn/--ctr-fail   N   % of a container's limit (default ${CTR_WARN}/${CTR_FAIL})
  -h, --help             Show this help and exit.

Lightweight READ-ONLY Pi hardware health probe (temp/throttle, disk, memory).
Exit: 0 on PASS/WARN/SKIP, 1 on FAIL, 2 on usage error.
EOF
}

# --- Parse arguments -------------------------------------------------------
_need() { [[ $# -ge 2 ]] || { err "$1 requires a value."; exit 2; }; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)      usage; exit 0 ;;
    -q|--quiet)     QUIET=1; shift ;;
    --no-docker)    DO_DOCKER=0; shift ;;
    --status-dir)   _need "$@"; STATUS_DIR="$2"; shift 2 ;;
    --status-dir=*) STATUS_DIR="${1#*=}"; shift ;;
    --docker-data)  _need "$@"; DOCKER_DATA_DIR="$2"; shift 2 ;;
    --docker-data=*) DOCKER_DATA_DIR="${1#*=}"; shift ;;
    --temp-warn) _need "$@"; TEMP_WARN="$2"; shift 2 ;; --temp-warn=*) TEMP_WARN="${1#*=}"; shift ;;
    --temp-fail) _need "$@"; TEMP_FAIL="$2"; shift 2 ;; --temp-fail=*) TEMP_FAIL="${1#*=}"; shift ;;
    --disk-warn) _need "$@"; DISK_WARN="$2"; shift 2 ;; --disk-warn=*) DISK_WARN="${1#*=}"; shift ;;
    --disk-fail) _need "$@"; DISK_FAIL="$2"; shift 2 ;; --disk-fail=*) DISK_FAIL="${1#*=}"; shift ;;
    --mem-warn)  _need "$@"; MEM_WARN="$2";  shift 2 ;; --mem-warn=*)  MEM_WARN="${1#*=}";  shift ;;
    --mem-fail)  _need "$@"; MEM_FAIL="$2";  shift 2 ;; --mem-fail=*)  MEM_FAIL="${1#*=}";  shift ;;
    --swap-warn) _need "$@"; SWAP_WARN="$2"; shift 2 ;; --swap-warn=*) SWAP_WARN="${1#*=}"; shift ;;
    --swap-fail) _need "$@"; SWAP_FAIL="$2"; shift 2 ;; --swap-fail=*) SWAP_FAIL="${1#*=}"; shift ;;
    --ctr-warn)  _need "$@"; CTR_WARN="$2";  shift 2 ;; --ctr-warn=*)  CTR_WARN="${1#*=}";  shift ;;
    --ctr-fail)  _need "$@"; CTR_FAIL="$2";  shift 2 ;; --ctr-fail=*)  CTR_FAIL="${1#*=}";  shift ;;
    -*)             err "Unknown option: '$1'."; echo >&2; usage; exit 2 ;;
    *)              err "Unexpected argument: '$1'."; usage; exit 2 ;;
  esac
done

# Validate every threshold is a non-negative integer (a typo must not silently
# disable a check).
for n in TEMP_WARN TEMP_FAIL DISK_WARN DISK_FAIL MEM_WARN MEM_FAIL SWAP_WARN SWAP_FAIL CTR_WARN CTR_FAIL; do
  if ! [[ "${!n}" =~ ^[0-9]+$ ]]; then err "${n} must be a non-negative integer (got '${!n}')."; exit 2; fi
done

# ===========================================================================
# Rendering helpers
# ===========================================================================
# Colour a verdict word.
vcol() {
  case "$1" in
    PASS) printf '%sPASS%s' "${C_GREEN}" "${C_OFF}" ;;
    WARN) printf '%sWARN%s' "${C_YELLOW}" "${C_OFF}" ;;
    FAIL) printf '%sFAIL%s' "${C_RED}" "${C_OFF}" ;;
    SKIP) printf '%sSKIP%s' "${C_DIM}" "${C_OFF}" ;;
    *)    printf '%s' "$1" ;;
  esac
}
# A check line:  [VERDICT] label — detail   (suppressed for PASS/SKIP in --quiet)
emit() {
  local verdict="$1" label="$2" detail="${3:-}"
  if (( QUIET )) && [[ "${verdict}" == "PASS" || "${verdict}" == "SKIP" ]]; then return 0; fi
  printf '  [%s] %-22s %s\n' "$(vcol "${verdict}")" "${label}" "${detail}"
}
section() { (( QUIET )) || printf '\n%s== %s ==%s\n' "${C_CYAN}" "$1" "${C_OFF}"; }

OVERALL="${HM_PASS}"
fold() { OVERALL="$(hm_worst "${OVERALL}" "$1")"; }
# Machine-readable per-section verdicts collected for the status JSON.
declare -A SECT=()
# Lines collected for the alert body (the WARN/FAIL detail, plain text).
declare -a ALERT_LINES=()
note_alert() { ALERT_LINES+=("$*"); }

(( QUIET )) || printf '%spi-system host health%s — read-only   (%s)\n' \
  "${C_BOLD}" "${C_OFF}" "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || true)"

# ===========================================================================
# CHECK 1 — CPU temperature + throttling
# ===========================================================================
section "Thermal (CPU temperature + throttling)"
TEMP_C=""
raw="$(hm_vcgencmd_temp)"
[[ -n "${raw}" ]] && TEMP_C="$(hm_parse_vcgencmd_temp "${raw}" 2>/dev/null || true)"
if [[ -z "${TEMP_C}" ]]; then
  raw="$(hm_read_thermal_zone)"
  [[ -n "${raw}" ]] && TEMP_C="$(hm_parse_thermal_zone "${raw}" 2>/dev/null || true)"
fi
if [[ -n "${TEMP_C}" ]]; then
  tv="$(hm_classify_high "${TEMP_C}" "${TEMP_WARN}" "${TEMP_FAIL}")"
  emit "${tv}" "CPU temperature" "${TEMP_C}°C (warn ${TEMP_WARN}, fail ${TEMP_FAIL})"
  SECT[temp]="${tv}"; fold "${tv}"
  [[ "${tv}" != "PASS" ]] && note_alert "CPU temperature ${TEMP_C}°C (${tv})"
else
  emit "SKIP" "CPU temperature" "no Pi thermal sensor here (not a Pi?)"
  SECT[temp]="SKIP"
fi

thr_raw="$(hm_vcgencmd_throttled)"
if [[ -n "${thr_raw}" ]]; then
  thv="$(hm_classify_throttled "${thr_raw}")"
  reasons="$(hm_throttled_reasons "${thr_raw}")"
  emit "${thv}" "Throttling flags" "${thr_raw#*=} ${reasons:+— ${reasons%; }}"
  SECT[throttle]="${thv}"; fold "${thv}"
  [[ "${thv}" != "PASS" && "${thv}" != "SKIP" ]] && note_alert "Throttling: ${reasons%; } (${thv})"
else
  emit "SKIP" "Throttling flags" "vcgencmd not available (not a Pi?)"
  SECT[throttle]="SKIP"
fi

# ===========================================================================
# CHECK 2 — Disk usage (root/SSD + Docker data dir) and the main consumer
# ===========================================================================
section "Disk (root/SSD + Docker data)"
disk_pct_for() { hm_df "$1" | hm_parse_df_pct 2>/dev/null || true; }
disk_avail_for() { hm_df "$1" | hm_parse_df_avail_kb 2>/dev/null || true; }

ROOT_PCT="$(disk_pct_for "/")"
if [[ -n "${ROOT_PCT}" ]]; then
  dv="$(hm_classify_high "${ROOT_PCT}" "${DISK_WARN}" "${DISK_FAIL}")"
  avail_kb="$(disk_avail_for "/")"; avail_h=""
  [[ "${avail_kb}" =~ ^[0-9]+$ ]] && avail_h="$(awk -v k="${avail_kb}" 'BEGIN{printf "%.1f GB free", k/1048576}')"
  emit "${dv}" "Root filesystem (/)" "${ROOT_PCT}% used${avail_h:+, ${avail_h}} (warn ${DISK_WARN}, fail ${DISK_FAIL})"
  SECT[disk_root]="${dv}"; fold "${dv}"
  [[ "${dv}" != "PASS" ]] && note_alert "Root filesystem ${ROOT_PCT}% used (${dv})"
else
  emit "SKIP" "Root filesystem (/)" "df unavailable"
  SECT[disk_root]="SKIP"
fi

# Docker data dir — only if it sits on a DIFFERENT filesystem than / (else it is
# already covered by the root check). Best-effort; SKIP if the path is absent.
if [[ -d "${DOCKER_DATA_DIR}" ]]; then
  DD_PCT="$(disk_pct_for "${DOCKER_DATA_DIR}")"
  if [[ -n "${DD_PCT}" && "${DD_PCT}" != "${ROOT_PCT}" ]]; then
    ddv="$(hm_classify_high "${DD_PCT}" "${DISK_WARN}" "${DISK_FAIL}")"
    emit "${ddv}" "Docker data dir" "${DOCKER_DATA_DIR}: ${DD_PCT}% used"
    SECT[disk_docker]="${ddv}"; fold "${ddv}"
    [[ "${ddv}" != "PASS" ]] && note_alert "Docker data dir ${DD_PCT}% used (${ddv})"
  else
    emit "PASS" "Docker data dir" "${DOCKER_DATA_DIR}: same filesystem as / (covered above)"
    SECT[disk_docker]="PASS"
  fi
else
  emit "SKIP" "Docker data dir" "${DOCKER_DATA_DIR} not present here"
  SECT[disk_docker]="SKIP"
fi

# When the disk is under pressure, name the likely culprit (backups vs Docker).
if [[ "${SECT[disk_root]:-}" != "PASS" && "${SECT[disk_root]:-}" != "SKIP" ]] \
   || [[ "${SECT[disk_docker]:-PASS}" != "PASS" && "${SECT[disk_docker]:-PASS}" != "SKIP" ]]; then
  bdir="${BACKUP_DIR_REL}"; [[ "${bdir}" == ./* ]] && bdir="${PROJECT_ROOT}/${bdir#./}"
  b_bytes="$(hm_du_bytes "${bdir}")"; d_bytes="$(hm_du_bytes "${DOCKER_DATA_DIR}")"
  consumer="$(printf 'backups\t%s\ndocker\t%s\n' "${b_bytes:-0}" "${d_bytes:-0}" | hm_largest)"
  human() { [[ "$1" =~ ^[0-9]+$ ]] && awk -v b="$1" 'BEGIN{printf "%.1f GB", b/1073741824}' || printf 'n/a'; }
  emit "WARN" "Top consumer" "${consumer:-unknown} (backups $(human "${b_bytes:-0}"), docker $(human "${d_bytes:-0}"))"
  note_alert "Disk pressure — biggest consumer: ${consumer:-unknown}"
fi

# ===========================================================================
# CHECK 3 — Live memory + swap
# ===========================================================================
section "Memory (live RAM + swap)"
free_out="$(hm_free)"
if [[ -n "${free_out}" ]]; then
  mtot="$(printf '%s\n' "${free_out}" | hm_free_field Mem total     2>/dev/null || true)"
  mav="$(printf '%s\n'  "${free_out}" | hm_free_field Mem available 2>/dev/null || true)"
  # Older `free` without an "available" column: fall back to free+buff/cache.
  if [[ -z "${mav}" ]]; then
    mfree="$(printf '%s\n' "${free_out}" | hm_free_field Mem free 2>/dev/null || echo 0)"
    mbuf="$(printf '%s\n'  "${free_out}" | hm_free_field Mem shared 2>/dev/null || echo 0)"
    mav="${mfree:-0}"
  fi
  mv="$(hm_classify_mem "${mtot:-0}" "${mav:-0}" "${MEM_WARN}" "${MEM_FAIL}")"
  usedpct="-"
  if [[ "${mtot:-0}" =~ ^[0-9]+$ ]] && (( mtot > 0 )); then usedpct=$(( (mtot - ${mav:-0}) * 100 / mtot )); fi
  emit "${mv}" "RAM" "${usedpct}% used (warn ${MEM_WARN}, fail ${MEM_FAIL})"
  SECT[mem]="${mv}"; fold "${mv}"
  [[ "${mv}" != "PASS" && "${mv}" != "SKIP" ]] && note_alert "RAM ${usedpct}% used (${mv})"

  stot="$(printf '%s\n' "${free_out}" | hm_free_field Swap total 2>/dev/null || echo 0)"
  sused="$(printf '%s\n' "${free_out}" | hm_free_field Swap used 2>/dev/null || echo 0)"
  sv="$(hm_classify_swap "${stot:-0}" "${sused:-0}" "${SWAP_WARN}" "${SWAP_FAIL}")"
  spct=0; [[ "${stot:-0}" =~ ^[0-9]+$ ]] && (( stot > 0 )) && spct=$(( sused * 100 / stot ))
  if [[ "${stot:-0}" =~ ^[0-9]+$ ]] && (( stot == 0 )); then
    emit "${sv}" "Swap" "none configured"
  else
    emit "${sv}" "Swap" "${spct}% used (warn ${SWAP_WARN}, fail ${SWAP_FAIL})"
  fi
  SECT[swap]="${sv}"; fold "${sv}"
  [[ "${sv}" != "PASS" && "${sv}" != "SKIP" ]] && note_alert "Swap ${spct}% used (${sv})"
else
  emit "SKIP" "RAM" "free(1) unavailable"
  SECT[mem]="SKIP"; SECT[swap]="SKIP"
fi

# ===========================================================================
# CHECK 4 — Per-container memory (docker stats --no-stream), top consumers
# ===========================================================================
section "Containers (live docker stats)"
if (( ! DO_DOCKER )); then
  emit "SKIP" "Per-container memory" "--no-docker"
  SECT[containers]="SKIP"
elif ! hm_docker_available; then
  emit "SKIP" "Per-container memory" "Docker not available here"
  SECT[containers]="SKIP"
else
  rows="$(hm_docker_stats | hm_stats_rows)"
  if [[ -z "${rows}" ]]; then
    emit "PASS" "Per-container memory" "no running containers"
    SECT[containers]="PASS"
  else
    cv="$(printf '%s\n' "${rows}" | hm_containers_verdict "${CTR_WARN}" "${CTR_FAIL}")"
    SECT[containers]="${cv}"; fold "${cv}"
    if (( ! QUIET )); then
      # Top 5 memory consumers, descending.
      printf '  %-26s %12s %8s %8s\n' "CONTAINER" "MEM (MiB)" "MEM%" "CPU%"
      printf '%s\n' "${rows}" | sort -t$'\t' -k2 -nr | head -n5 \
        | awk -F'\t' '{ printf "  %-26s %12s %7s%% %7s%%\n", $1, $2, $4, $5 }'
    fi
    near="$(printf '%s\n' "${rows}" | hm_containers_near_limit "${CTR_WARN}")"
    if [[ -n "${near}" ]]; then
      while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        emit "${cv}" "Near its limit" "${line}"
        note_alert "Container near limit: ${line}"
      done <<< "${near}"
    else
      emit "PASS" "Per-container memory" "all containers comfortably under their limits"
    fi
  fi
fi

# ===========================================================================
# VERDICT
# ===========================================================================
# An all-SKIP run (nothing measurable on this host) is reported as WARN: we
# learned nothing, which is itself worth a heads-up — but never a hard FAIL.
EFFECTIVE="${OVERALL}"
[[ "${OVERALL}" == "${HM_SKIP}" ]] && EFFECTIVE="${HM_WARN}"

printf '\n'
case "${EFFECTIVE}" in
  PASS) printf '%sVERDICT: PASS%s — host is healthy.\n' "${C_GREEN}${C_BOLD}" "${C_OFF}" ;;
  WARN) printf '%sVERDICT: WARN%s — attention recommended (see above).\n' "${C_YELLOW}${C_BOLD}" "${C_OFF}" ;;
  FAIL) printf '%sVERDICT: FAIL%s — a resource is over its hard threshold.\n' "${C_RED}${C_BOLD}" "${C_OFF}" >&2 ;;
esac

# ===========================================================================
# OUTPUT — status file, log, and (on WARN/FAIL) the swappable notifier.
# Only when --status-dir / HEALTH_STATUS_DIR is set (the cron job sets it). A
# bare interactive run stays pure stdout, writing nothing.
# ===========================================================================
write_status_and_notify() {
  local dir="$1" ts finished
  mkdir -p "${dir}"
  ts="$(date +%Y-%m-%dT%H:%M:%S%z 2>/dev/null || echo unknown)"
  finished="${ts}"

  # Machine-readable status (no secrets — only verdicts + measured numbers).
  cat >"${dir}/last-health.json" <<JSON
{
  "checked_at": "${finished}",
  "verdict": "${EFFECTIVE}",
  "sections": {
    "temp": "${SECT[temp]:-SKIP}",
    "throttle": "${SECT[throttle]:-SKIP}",
    "disk_root": "${SECT[disk_root]:-SKIP}",
    "disk_docker": "${SECT[disk_docker]:-SKIP}",
    "mem": "${SECT[mem]:-SKIP}",
    "swap": "${SECT[swap]:-SKIP}",
    "containers": "${SECT[containers]:-SKIP}"
  },
  "measured": {
    "cpu_temp_c": "${TEMP_C:-}",
    "root_pct": "${ROOT_PCT:-}",
    "mem_used_pct": "${usedpct:-}",
    "swap_used_pct": "${spct:-}"
  }
}
JSON

  # Append a one-line log entry (the zero-config history; rotated by its own
  # size guard below so it can never itself fill the SSD).
  local logf="${dir}/health.log"
  printf '%s  %-4s  temp=%s°C root=%s%% mem=%s%% swap=%s%%\n' \
    "${finished}" "${EFFECTIVE}" "${TEMP_C:-?}" "${ROOT_PCT:-?}" "${usedpct:-?}" "${spct:-?}" >>"${logf}"
  # Keep health.log bounded (~2000 lines ≈ years of 15-min runs) — trim in place.
  if [[ -f "${logf}" ]]; then
    local lines; lines="$(wc -l <"${logf}" 2>/dev/null || echo 0)"
    if [[ "${lines}" =~ ^[0-9]+$ ]] && (( lines > 2000 )); then
      tail -n 1500 "${logf}" >"${logf}.tmp" 2>/dev/null && mv "${logf}.tmp" "${logf}"
    fi
  fi

  # SWAPPABLE NOTIFIER — only on WARN/FAIL (PASS/SKIP are silent).
  if hm_should_notify "${EFFECTIVE}"; then
    local body alertf="${dir}/last-alert.txt"
    body="$(printf 'pi-system health %s @ %s\n' "${EFFECTIVE}" "${finished}"; printf '  - %s\n' "${ALERT_LINES[@]:-no detail}")"
    # 1) Default safe channel: an alert file Uptime Kuma / the operator can watch.
    printf '%s\n' "${body}" >"${alertf}"
    # 2) Optional Uptime Kuma push (URL only; no secret in git). PASS/WARN=up, FAIL=down.
    if [[ -n "${KUMA_URL}" ]] && hm_have_cmd curl; then
      local kstatus kmsg
      kstatus="$(hm_kuma_status "${EFFECTIVE}")"
      kmsg="$(hm_slug "health-${EFFECTIVE}")"
      curl -fsS -m 10 "${KUMA_URL}?status=${kstatus}&msg=${kmsg}&ping=" >/dev/null 2>&1 || true
    fi
    # 3) Optional operator-supplied notifier command. We pass verdict as $1 and
    #    the plain-text body on stdin. Keep tokens INSIDE your own script/env —
    #    never here. (e.g. HEALTH_NOTIFY_CMD=./secrets/notify-telegram.sh)
    if [[ -n "${NOTIFY_CMD}" ]]; then
      printf '%s\n' "${body}" | ${NOTIFY_CMD} "${EFFECTIVE}" >/dev/null 2>&1 || true
    fi
  else
    # Clear any stale alert once we are healthy again.
    rm -f "${dir}/last-alert.txt" 2>/dev/null || true
  fi
}

if [[ -n "${STATUS_DIR}" ]]; then
  sdir="${STATUS_DIR}"; [[ "${sdir}" == ./* ]] && sdir="${PROJECT_ROOT}/${sdir#./}"
  write_status_and_notify "${sdir}"
  (( QUIET )) || printf '%sStatus written:%s %s/last-health.json\n' "${C_DIM}" "${C_OFF}" "${sdir#${PROJECT_ROOT}/}"
fi

# Exit non-zero ONLY on a hard FAIL (so cron logs flag it); PASS/WARN/SKIP = 0.
[[ "${OVERALL}" == "${HM_FAIL}" ]] && exit 1
exit 0
