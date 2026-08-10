#!/usr/bin/env bash
# ===========================================================================
# pi-system — install the scheduled SEO audit (host cron)
# ---------------------------------------------------------------------------
# Installs ONE cron job for the CURRENT user:
#   * a WEEKLY SEO/site-quality audit of every site in your list ->
#       ./scripts/seo.sh audit all
#
# WHY host cron (and not an always-on scheduler / browser):
#   * The auditor is a ONE-SHOT container that exists only for the seconds an audit
#     takes — nothing sits idle 24/7. On a Pi, RAM is precious; an always-on browser
#     is exactly what this design avoids (see services/seo/README.md).
#   * cron is the Pi-native, battle-tested scheduler — the SAME pattern used by
#     scripts/backup-install-cron.sh and scripts/health-monitor-install-cron.sh.
#
# OPERATOR-RUN and SAFE: it only edits YOUR crontab, is idempotent (re-running
# replaces the pi-system SEO block, never duplicates it), prints exactly what it
# will install, and supports --dry-run and --remove.
#
# Usage:
#     ./scripts/seo-install-cron.sh [options]
#
#       --weekly "<cron>"   Schedule for the audit (default: "45 4 * * 1" = Mon 04:45)
#       --dry-run           Print the crontab block; install nothing.
#       --remove            Remove the pi-system SEO cron block and exit.
#   -h, --help              Show this help and exit.
#
# Logs append to ${SEO_DATA_DIR:-./data/seo}/cron.log.
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

log()  { printf '\033[0;32m[cron]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

MARK_BEGIN="# >>> pi-system seo audit schedule >>>"
MARK_END="# <<< pi-system seo audit schedule <<<"

WEEKLY="45 4 * * 1"      # Monday 04:45 (off-peak)
DRYRUN=0
REMOVE=0

usage() {
  cat >&2 <<EOF
Usage: ./scripts/seo-install-cron.sh [options]

      --weekly "<cron>"   Audit schedule (default: "${WEEKLY}")
      --dry-run           Print the crontab block; install nothing.
      --remove            Remove the pi-system SEO cron block and exit.
  -h, --help              Show this help and exit.

Installs a weekly "seo.sh audit all" into the current user's crontab. Idempotent.
See docs/README.md "SEO & site quality".
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --weekly) WEEKLY="${2:-}"; shift 2 ;;
    --weekly=*) WEEKLY="${1#*=}"; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --remove) REMOVE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; usage; exit 1 ;;
  esac
done

command -v crontab >/dev/null 2>&1 || { err "crontab not found. Install cron (e.g. 'sudo apt-get install -y cron')."; exit 1; }
[[ -f "scripts/seo.sh" ]] || { err "scripts/seo.sh not found."; exit 1; }

LOG_DIR="${SEO_DATA_DIR:-./data/seo}"
LOG_FILE="${PROJECT_ROOT}/${LOG_DIR#./}/cron.log"

current_without_block() {
  crontab -l 2>/dev/null | awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" '
    $0==b {skip=1; next} $0==e {skip=0; next} skip!=1 {print}
  ' || true
}

if [[ "${REMOVE}" -eq 1 ]]; then
  if ! crontab -l 2>/dev/null | grep -qF "${MARK_BEGIN}"; then
    log "No pi-system SEO cron block found — nothing to remove."
    exit 0
  fi
  current_without_block | crontab -
  log "Removed the pi-system SEO cron block from your crontab."
  exit 0
fi

BLOCK="$(cat <<EOF
${MARK_BEGIN}
# Managed by scripts/seo-install-cron.sh — edit via that script, not by hand.
# Weekly SEO/site-quality audit of every site in data/seo/sites.conf.
${WEEKLY} cd ${PROJECT_ROOT} && /usr/bin/env bash scripts/seo.sh audit all >> ${LOG_FILE} 2>&1
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
log "Audit logs will append to: ${LOG_FILE#${PROJECT_ROOT}/}"
warn "Create your sites list first:  cp services/seo/sites.example.conf ${LOG_DIR}/sites.conf"
warn "Confirm the schedule survives reboots: 'systemctl status cron' (Debian/Pi OS)."
