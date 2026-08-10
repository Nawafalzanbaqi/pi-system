#!/usr/bin/env bash
# ===========================================================================
# pi-system — install the host-health-monitor schedule (host cron)
# ---------------------------------------------------------------------------
# Installs ONE low-frequency cron job for the CURRENT user:
#   * every 15 minutes  ->  ./scripts/health-monitor.sh --quiet --status-dir <dir>
#
# WHY host cron (the SAME mechanism the backup system uses — see
# scripts/backup-install-cron.sh; one transparent scheduler, no parallel one):
#   * The probe must read the Pi's THERMAL SENSOR and run `docker stats` on the
#     HOST — both are host-level reads, so the host is the natural place to run.
#   * On a Pi, RAM is precious. The probe is a one-shot script that exists only
#     for the second it takes to sample — nothing sits idle 24/7 (no agent, no
#     Grafana/Prometheus; that does not belong on a constrained Pi).
#   * cron is the Pi-native, battle-tested scheduler; no extra process needed.
#
# This script is OPERATOR-RUN and SAFE: it only edits YOUR crontab, is
# idempotent (re-running replaces the pi-system block, never duplicates it),
# prints exactly what it will install, and supports --dry-run and --remove.
#
# Usage:
#     ./scripts/health-monitor-install-cron.sh [options]
#
#       --schedule "<cron>"  Schedule (default: "*/15 * * * *" — every 15 min)
#       --status-dir DIR     Where to write last-health.json + health.log
#                            (default: ./data/health)
#       --dry-run            Print the crontab block; install nothing.
#       --remove             Remove the pi-system health-monitor block and exit.
#   -h, --help               Show this help and exit.
#
# The job runs with --quiet, so cron only logs a line on each run; WARN/FAIL
# detail and the swappable notifier are driven by --status-dir (see
# docs/README.md "Resource monitoring").
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers (same shape as backup-install-cron.sh) ----------
log()  { printf '\033[0;32m[cron]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

MARK_BEGIN="# >>> pi-system health-monitor schedule >>>"
MARK_END="# <<< pi-system health-monitor schedule <<<"

SCHEDULE="*/15 * * * *"               # every 15 minutes
STATUS_DIR="${HEALTH_STATUS_DIR:-./data/health}"
DRYRUN=0
REMOVE=0

usage() {
  cat >&2 <<EOF
Usage: ./scripts/health-monitor-install-cron.sh [options]

      --schedule "<cron>"  Schedule (default: "${SCHEDULE}")
      --status-dir DIR     Status/log directory (default: "${STATUS_DIR}")
      --dry-run            Print the crontab block; install nothing.
      --remove             Remove the pi-system health-monitor block and exit.
  -h, --help               Show this help and exit.

Installs a low-frequency host health probe into the current user's crontab.
Idempotent. See docs/README.md "Resource monitoring".
EOF
}

# --- Parse arguments -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --schedule) SCHEDULE="${2:-}"; shift 2 ;;
    --schedule=*) SCHEDULE="${1#*=}"; shift ;;
    --status-dir) STATUS_DIR="${2:-}"; shift 2 ;;
    --status-dir=*) STATUS_DIR="${1#*=}"; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; usage; exit 1 ;;
  esac
done

# --- Preconditions ---------------------------------------------------------
command -v crontab >/dev/null 2>&1 || { err "crontab not found. Install cron (e.g. 'sudo apt-get install -y cron')."; exit 1; }
[[ -f "scripts/health-monitor.sh" ]] || { err "scripts/health-monitor.sh not found."; exit 1; }

LOG_FILE="${PROJECT_ROOT}/${STATUS_DIR#./}/cron.log"

# Current crontab WITHOUT our managed block (so we can re-add it cleanly).
current_without_block() {
  crontab -l 2>/dev/null | awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
    $0==b {skip=1; next} $0==e {skip=0; next} skip!=1 {print}
  ' || true
}

# --- Remove mode -----------------------------------------------------------
if [[ "${REMOVE}" -eq 1 ]]; then
  if ! crontab -l 2>/dev/null | grep -qF "${MARK_BEGIN}"; then
    log "No pi-system health-monitor cron block found — nothing to remove."
    exit 0
  fi
  current_without_block | crontab -
  log "Removed the pi-system health-monitor cron block from your crontab."
  exit 0
fi

# --- Build the managed block ----------------------------------------------
# Absolute paths so cron (which has a minimal PATH/CWD) runs the right script.
BLOCK="$(cat <<EOF
${MARK_BEGIN}
# Managed by scripts/health-monitor-install-cron.sh — edit via that script, not by hand.
# Low-frequency, read-only Pi hardware health probe (temp/disk/memory). On
# WARN/FAIL it updates the status file + fires the swappable notifier.
${SCHEDULE} cd ${PROJECT_ROOT} && /usr/bin/env bash scripts/health-monitor.sh --quiet --status-dir ${STATUS_DIR} >> ${LOG_FILE} 2>&1
${MARK_END}
EOF
)"

echo
log "The following cron block will be installed for user '$(id -un)':"
echo "------------------------------------------------------------"
printf '%s\n' "${BLOCK}"
echo "------------------------------------------------------------"

if [[ "${DRYRUN}" -eq 1 ]]; then
  log "[dry-run] Nothing installed. Re-run without --dry-run to apply."
  exit 0
fi

mkdir -p "$(dirname "${LOG_FILE}")"
{ current_without_block; printf '%s\n' "${BLOCK}"; } | crontab -

log "Installed. Verify with:  crontab -l"
log "Health status will be written to: ${STATUS_DIR#./}/last-health.json"
log "Per-run cron output appends to:  ${STATUS_DIR#./}/cron.log"
warn "Tune thresholds via .env (HEALTH_* vars) or flags — see docs/README.md."
warn "Confirm the schedule survives reboots: 'systemctl status cron' (Debian/Pi OS)."
