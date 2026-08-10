#!/usr/bin/env bash
# ===========================================================================
# pi-system — install the scheduled FOLLOW-UP REMINDER (host cron)
# ---------------------------------------------------------------------------
# Installs ONE cron job for the CURRENT user:
#   * a DAILY check for prospect follow-ups that are DUE, which reminds YOU ->
#       ./scripts/prospects.sh followups --notify
#
# WHAT THIS DOES — and explicitly does NOT do:
#   * It surfaces YOUR own due follow-ups and (via PROSPECTS_NOTIFY_CMD / Uptime
#     Kuma, if configured) nudges YOU on YOUR OWN channel to reach out manually.
#   * It NEVER contacts a prospect. There is no outbound-to-prospect path anywhere
#     in this tool — the reminder is to the OPERATOR only (see services/prospects/
#     README.md). Outreach stays manual.
#
# WHY host cron (and not an always-on scheduler):
#   * The organizer is a ONE-SHOT container that exists only for the seconds the
#     check takes — nothing sits idle 24/7 (the SAME Pi-aware design as the SEO
#     auditor). cron is the Pi-native scheduler used by scripts/seo-install-cron.sh,
#     scripts/backup-install-cron.sh and scripts/health-monitor-install-cron.sh.
#
# OPERATOR-RUN and SAFE: it only edits YOUR crontab, is idempotent (re-running
# replaces the pi-system prospects block, never duplicates it), prints exactly what
# it will install, and supports --dry-run and --remove.
#
# Usage:
#     ./scripts/prospects-install-cron.sh [options]
#
#       --daily "<cron>"    Schedule for the reminder (default: "30 8 * * *" = 08:30 daily)
#       --dry-run           Print the crontab block; install nothing.
#       --remove            Remove the pi-system prospects cron block and exit.
#   -h, --help              Show this help and exit.
#
# Logs append to ${PROSPECTS_DATA_DIR:-./data/prospects}/cron.log.
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

log()  { printf '\033[0;32m[cron]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

MARK_BEGIN="# >>> pi-system prospects follow-up reminder >>>"
MARK_END="# <<< pi-system prospects follow-up reminder <<<"

DAILY="30 8 * * *"      # 08:30 every day
DRYRUN=0
REMOVE=0

usage() {
  cat >&2 <<EOF
Usage: ./scripts/prospects-install-cron.sh [options]

      --daily "<cron>"    Reminder schedule (default: "${DAILY}")
      --dry-run           Print the crontab block; install nothing.
      --remove            Remove the pi-system prospects cron block and exit.
  -h, --help              Show this help and exit.

Installs a daily "prospects.sh followups --notify" into the current user's crontab.
It reminds YOU (the operator) of due follow-ups; it never contacts a prospect.
Idempotent. See docs/README.md "Client prospect organizer".
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --daily) DAILY="${2:-}"; shift 2 ;;
    --daily=*) DAILY="${1#*=}"; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; usage; exit 1 ;;
  esac
done

command -v crontab >/dev/null 2>&1 || { err "crontab not found. Install cron (e.g. 'sudo apt-get install -y cron')."; exit 1; }
[[ -f "scripts/prospects.sh" ]] || { err "scripts/prospects.sh not found."; exit 1; }

LOG_DIR="${PROSPECTS_DATA_DIR:-./data/prospects}"
LOG_FILE="${PROJECT_ROOT}/${LOG_DIR#./}/cron.log"

current_without_block() {
  crontab -l 2>/dev/null | awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
    $0==b {skip=1; next} $0==e {skip=0; next} skip!=1 {print}
  ' || true
}

if [[ "${REMOVE}" -eq 1 ]]; then
  if ! crontab -l 2>/dev/null | grep -qF "${MARK_BEGIN}"; then
    log "No pi-system prospects cron block found — nothing to remove."
    exit 0
  fi
  current_without_block | crontab -
  log "Removed the pi-system prospects cron block from your crontab."
  exit 0
fi

BLOCK="$(cat <<EOF
${MARK_BEGIN}
# Managed by scripts/prospects-install-cron.sh — edit via that script, not by hand.
# Daily reminder of YOUR due prospect follow-ups (never contacts a prospect).
${DAILY} cd ${PROJECT_ROOT} && /usr/bin/env bash scripts/prospects.sh followups --notify >> ${LOG_FILE} 2>&1
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
log "Reminder logs will append to: ${LOG_FILE#${PROJECT_ROOT}/}"
warn "To deliver the reminder to your OWN channel, set PROSPECTS_NOTIFY_CMD in .env."
warn "Confirm the schedule survives reboots: 'systemctl status cron' (Debian/Pi OS)."
