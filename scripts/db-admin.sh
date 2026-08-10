#!/usr/bin/env bash
# ===========================================================================
# pi-system — on-demand database admin UI helper
# ---------------------------------------------------------------------------
# Start/stop/inspect a SINGLE database admin UI on demand. Each UI lives behind
# its own Compose profile in services/db-admin/db-admin.compose.yml, so this
# helper just runs the right `docker compose` command with:
#   * the BASE compose file (so the shared `internal` / `proxy` networks
#     resolve), AND
#   * the db-admin compose file, AND
#   * the matching --profile, so only the requested UI is touched.
#
# Usage:
#     ./scripts/db-admin.sh <ui> <action>
#
#   <ui>      pgadmin | adminer | mongo-express
#   <action>  up      start that admin UI (detached)
#             down    stop AND remove ONLY that container (pgAdmin's data volume
#                     is kept; Adminer + Mongo Express hold no state)
#             logs    follow that UI's logs (Ctrl-C to stop)
#             status  show that UI's container status
#
# Examples:
#     ./scripts/db-admin.sh pgadmin up
#     ./scripts/db-admin.sh adminer status
#     ./scripts/db-admin.sh mongo-express down
#
# REMINDER: start the matching DATABASE first (e.g. ./scripts/db.sh postgres up
# before pgadmin), and make sure Caddy is up (./scripts/start-proxy.sh) — the
# UIs publish no host ports and are reached only through the reverse proxy.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[db-admin]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
ADMIN_COMPOSE="services/db-admin/db-admin.compose.yml"

VALID_UIS="pgadmin adminer mongo-express"
VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/db-admin.sh <ui> <action>

  <ui>       pgadmin | adminer | mongo-express
  <action>   up | down | logs | status

  up      start that admin UI (detached)
  down    stop and remove ONLY that container (pgAdmin's data volume is kept)
  logs    follow that UI's logs (Ctrl-C to stop)
  status  show that UI's container status

Examples:
  ./scripts/db-admin.sh pgadmin up
  ./scripts/db-admin.sh adminer status
  ./scripts/db-admin.sh mongo-express down

Reminder: start the matching database first (e.g. ./scripts/db.sh postgres up)
and ensure Caddy is running (./scripts/start-proxy.sh).
EOF
}

# Is "$1" a whitespace-separated member of "$2"?
contains() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Print the database profile a given UI fronts (for the start-up reminder).
db_for_ui() {
  case "$1" in
    pgadmin)       echo "postgres" ;;
    adminer)       echo "postgres or mysql" ;;
    mongo-express) echo "mongo" ;;
  esac
}

# --- Validate arguments ----------------------------------------------------
if [[ $# -ne 2 ]]; then
  err "Expected exactly 2 arguments, got $#."
  usage
  exit 1
fi
UI="$1"
ACTION="$2"

if ! contains "${UI}" "${VALID_UIS}"; then
  err "Unknown UI: '${UI}'. Valid UIs: ${VALID_UIS}."
  usage
  exit 1
fi
if ! contains "${ACTION}" "${VALID_ACTIONS}"; then
  err "Unknown action: '${ACTION}'. Valid actions: ${VALID_ACTIONS}."
  usage
  exit 1
fi

# The profile name and the service name both equal the UI name.
SERVICE="${UI}"

# --- Preconditions ---------------------------------------------------------
if [[ ! -f ".env" ]]; then
  err ".env not found. Run ./scripts/setup.sh first, then edit .env."
  exit 1
fi
for f in "${BASE_COMPOSE}" "${ADMIN_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + db-admin files together, with the UI's profile enabled, so the shared
# `internal` / `proxy` networks resolve and only this UI is in scope.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${ADMIN_COMPOSE}" --profile "${UI}")

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    log "Starting '${UI}' (profile: ${UI}) ..."
    "${COMPOSE[@]}" up -d "${SERVICE}"
    "${COMPOSE[@]}" ps "${SERVICE}"
    # Report the subdomain Caddy fronts it at (BASE_DOMAIN -> localhost default).
    DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
    DOMAIN="${DOMAIN:-localhost}"
    log "'${UI}' is up — reach it via Caddy at https://${UI}.${DOMAIN}"
    warn "Make sure the matching database is running (e.g. ./scripts/db.sh $(db_for_ui "${UI}") up) and Caddy is up (./scripts/start-proxy.sh)."
    ;;
  down)
    # Targeted removal: stop + remove ONLY this container (-s stop, -f no
    # prompt). We deliberately do NOT use `compose down`, which would tear
    # down the whole pi-system project. pgAdmin's named volume is preserved.
    log "Stopping and removing the '${UI}' container ..."
    "${COMPOSE[@]}" rm -sf "${SERVICE}"
    log "'${UI}' removed. Any named data volume (e.g. pgadmin_data) was NOT touched."
    ;;
  logs)
    log "Following '${UI}' logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200 "${SERVICE}"
    ;;
  status)
    "${COMPOSE[@]}" ps "${SERVICE}"
    ;;
esac
