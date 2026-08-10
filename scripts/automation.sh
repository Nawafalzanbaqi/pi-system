#!/usr/bin/env bash
# ===========================================================================
# pi-system — automation stack helper (n8n)
# ---------------------------------------------------------------------------
# Start/stop/inspect the automation stack as a unit: n8n together with its OWN
# dedicated PostgreSQL (n8n-db), defined in
# services/automation/automation.compose.yml. Like the auth helper there are no
# profiles here — n8n and its DB always come up together — so this helper just
# runs the right `docker compose` command with:
#   * the BASE compose file (so the shared `internal` / `proxy` networks
#     resolve), AND
#   * the automation compose file.
#
# Usage:
#     ./scripts/automation.sh <action>
#
#   <action>  up      start the automation stack (n8n-db + n8n, detached)
#             down    stop AND remove ONLY the automation containers (the
#                     n8n_db_data + n8n_data volumes — all workflow/credential
#                     data — are kept)
#             logs    follow the automation stack's logs (Ctrl-C to stop)
#             status  show the automation containers' status
#
# Examples:
#     ./scripts/automation.sh up
#     ./scripts/automation.sh status
#     ./scripts/automation.sh down
#
# REMINDER: n8n is reached only through Caddy, so make sure the proxy is up
# (./scripts/start-proxy.sh) to actually open https://automation.<BASE_DOMAIN>.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[automation]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
AUTOMATION_COMPOSE="services/automation/automation.compose.yml"

# The two services this stack owns (used by the targeted `down`).
SERVICES="n8n n8n-db"

VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/automation.sh <action>

  <action>   up | down | logs | status

  up      start the automation stack (n8n-db + n8n, detached)
  down    stop and remove ONLY the automation containers (the n8n_db_data and
          n8n_data volumes — all workflow/credential data — are kept)
  logs    follow the automation stack's logs (Ctrl-C to stop)
  status  show the automation containers' status

Examples:
  ./scripts/automation.sh up
  ./scripts/automation.sh status
  ./scripts/automation.sh down

Reminder: n8n is reached only via Caddy — ensure the proxy is running
(./scripts/start-proxy.sh) to open https://automation.<BASE_DOMAIN>.
EOF
}

# Is "$1" a whitespace-separated member of "$2"?
contains() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- Validate arguments ----------------------------------------------------
if [[ $# -ne 1 ]]; then
  err "Expected exactly 1 argument, got $#."
  usage
  exit 1
fi
ACTION="$1"

if ! contains "${ACTION}" "${VALID_ACTIONS}"; then
  err "Unknown action: '${ACTION}'. Valid actions: ${VALID_ACTIONS}."
  usage
  exit 1
fi

# --- Preconditions ---------------------------------------------------------
if [[ ! -f ".env" ]]; then
  err ".env not found. Run ./scripts/setup.sh first, then edit .env."
  exit 1
fi
for f in "${BASE_COMPOSE}" "${AUTOMATION_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + automation files together so the shared `internal` / `proxy` networks
# resolve and n8n can both reach its DB (and the services it monitors) and be
# fronted by Caddy.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${AUTOMATION_COMPOSE}")

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    log "Starting the automation stack (n8n-db + n8n) ..."
    warn "n8n's first boot runs database migrations and can take a minute or"
    warn "more on a Pi. Watch progress with: ./scripts/automation.sh logs"
    "${COMPOSE[@]}" up -d
    "${COMPOSE[@]}" ps
    # Report the subdomain Caddy fronts it at (BASE_DOMAIN -> localhost default).
    DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
    DOMAIN="${DOMAIN:-localhost}"
    log "n8n is starting — once ready, reach it via Caddy at https://automation.${DOMAIN}"
    log "On first visit, create the n8n owner account (email + password) to log in."
    warn "Make sure Caddy is up (./scripts/start-proxy.sh) to actually open that URL."
    ;;
  down)
    # Targeted removal: stop + remove ONLY the automation containers (-s stop,
    # -f no prompt). We deliberately do NOT use `compose down`, which would tear
    # down the whole pi-system project. The n8n_db_data + n8n_data volumes are
    # preserved.
    log "Stopping and removing the automation containers (data volumes kept) ..."
    "${COMPOSE[@]}" rm -sf ${SERVICES}
    log "Automation stack removed. Its data volumes (n8n_db_data, n8n_data) were NOT touched."
    ;;
  logs)
    log "Following the automation stack's logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200
    ;;
  status)
    "${COMPOSE[@]}" ps
    ;;
esac
