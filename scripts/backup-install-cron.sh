#!/usr/bin/env bash
# ===========================================================================
# pi-system — install the backup + restore-drill schedule (host cron)
# ---------------------------------------------------------------------------
# Installs two cron jobs for the CURRENT user:
#   * a DAILY encrypted backup            -> ./scripts/backup.sh now
#   * a WEEKLY automated restore drill    -> ./scripts/backup-verify.sh
#
# WHY host cron (and not an always-on scheduler container):
#   * The restore DRILL must CREATE and DESTROY disposable containers — a
#     Docker-daemon operation. Keeping ALL scheduling on the host (one
#     mechanism) is simpler and more transparent than splitting it between an
#     in-container cron and the host, and it avoids granting a long-running
#     backup container access to the Docker socket.
#   * On a Pi, RAM is precious. The backup runs as a one-shot container that
#     exists only for the seconds it takes to dump — nothing sits idle 24/7.
#   * cron is the Pi-native, battle-tested scheduler; no extra process needed.
#
# This script is OPERATOR-RUN and SAFE: it only edits YOUR crontab, is
# idempotent (re-running replaces the pi-system block, never duplicates it),
# prints exactly what it will install, and supports --dry-run and --remove.
#
# Usage:
#     ./scripts/backup-install-cron.sh [options]
#
#       --daily  "<cron>"   Schedule for the daily backup  (default: "30 2 * * *")
#       --weekly "<cron>"   Schedule for the weekly drill   (default: "30 3 * * 0")
#       --dry-run           Print the crontab block; install nothing.
#       --remove            Remove the pi-system backup cron block and exit.
#   -h, --help              Show this help and exit.
#
# Logs go to ${BACKUP_DIR:-./data/backups}/status/cron.log (rotated by retention
# of the backups themselves; this is just an append log).
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[cron]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

MARK_BEGIN="# >>> pi-system backup schedule >>>"
MARK_END="# <<< pi-system backup schedule <<<"

DAILY="30 2 * * *"       # 02:30 every day
WEEKLY="30 3 * * 0"      # 03:30 every Sunday
DRYRUN=0
REMOVE=0

usage() {
  cat >&2 <<EOF
Usage: ./scripts/backup-install-cron.sh [options]

      --daily  "<cron>"   Daily backup schedule  (default: "${DAILY}")
      --weekly "<cron>"   Weekly drill schedule  (default: "${WEEKLY}")
      --dry-run           Print the crontab block; install nothing.
      --remove            Remove the pi-system backup cron block and exit.
  -h, --help              Show this help and exit.

Installs a daily backup + weekly restore drill into the current user's crontab.
Idempotent. See docs/README.md "Backup & restore".
EOF
}

# --- Parse arguments -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --daily) DAILY="${2:-}"; shift 2 ;;
    --daily=*) DAILY="${1#*=}"; shift ;;
    --weekly) WEEKLY="${2:-}"; shift 2 ;;
    --weekly=*) WEEKLY="${1#*=}"; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; usage; exit 1 ;;
  esac
done

# --- Preconditions ---------------------------------------------------------
command -v crontab >/dev/null 2>&1 || { err "crontab not found. Install cron (e.g. 'sudo apt-get install -y cron')."; exit 1; }
[[ -f "scripts/backup.sh" ]] || { err "scripts/backup.sh not found."; exit 1; }
[[ -f "scripts/backup-verify.sh" ]] || { err "scripts/backup-verify.sh not found."; exit 1; }

LOG_DIR="${BACKUP_DIR:-./data/backups}/status"
LOG_FILE="${PROJECT_ROOT}/${LOG_DIR#./}/cron.log"

# Current crontab WITHOUT our managed block (so we can re-add it cleanly).
current_without_block() {
  crontab -l 2>/dev/null | awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
    $0==b {skip=1; next} $0==e {skip=0; next} skip!=1 {print}
  ' || true
}

# --- Remove mode -----------------------------------------------------------
if [[ "${REMOVE}" -eq 1 ]]; then
  if ! crontab -l 2>/dev/null | grep -qF "${MARK_BEGIN}"; then
    log "No pi-system backup cron block found — nothing to remove."
    exit 0
  fi
  current_without_block | crontab -
  log "Removed the pi-system backup cron block from your crontab."
  exit 0
fi

# --- Build the managed block ----------------------------------------------
# Absolute paths so cron (which has a minimal PATH/CWD) runs the right scripts.
BLOCK="$(cat <<EOF
${MARK_BEGIN}
# Managed by scripts/backup-install-cron.sh — edit via that script, not by hand.
# Daily encrypted backup of every running database + config.
${DAILY} cd ${PROJECT_ROOT} && /usr/bin/env bash scripts/backup.sh now >> ${LOG_FILE} 2>&1
# Weekly TESTED-RESTORE drill into disposable throwaway containers.
${WEEKLY} cd ${PROJECT_ROOT} && /usr/bin/env bash scripts/backup-verify.sh >> ${LOG_FILE} 2>&1
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
log "Backup logs will append to: ${LOG_FILE#${PROJECT_ROOT}/}"
warn "Make sure the age key exists first:  ./scripts/backup.sh init-key"
warn "Confirm the schedule survives reboots: 'systemctl status cron' (Debian/Pi OS)."
