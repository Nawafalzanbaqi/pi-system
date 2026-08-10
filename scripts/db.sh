#!/usr/bin/env bash
# ===========================================================================
# pi-system — on-demand database helper
# ---------------------------------------------------------------------------
# Start/stop/inspect a SINGLE database on demand. Each engine lives behind its
# own Compose profile in services/databases/databases.compose.yml, so this
# helper just runs the right `docker compose` command with:
#   * the BASE compose file (so the shared `internal` network resolves), AND
#   * the databases compose file, AND
#   * the matching --profile, so only the requested engine is touched.
#
# Usage:
#     ./scripts/db.sh <engine> <action>
#
#   <engine>  postgres | mysql | mongo | redis
#   <action>  up      start that database (detached)
#             down    stop AND remove ONLY that container (its data volume is
#                     kept, so nothing is lost)
#             logs    follow that database's logs (Ctrl-C to stop)
#             status  show that database's container status
#
# Examples:
#     ./scripts/db.sh postgres up
#     ./scripts/db.sh redis status
#     ./scripts/db.sh mongo down
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[db]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
DB_COMPOSE="services/databases/databases.compose.yml"

VALID_ENGINES="postgres mysql mongo redis"
VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/db.sh <engine> <action>

  <engine>   postgres | mysql | mongo | redis
  <action>   up | down | logs | status

  up      start that database (detached)
  down    stop and remove ONLY that container (its data volume is kept)
  logs    follow that database's logs (Ctrl-C to stop)
  status  show that database's container status

Examples:
  ./scripts/db.sh postgres up
  ./scripts/db.sh redis status
  ./scripts/db.sh mongo down
EOF
}

# Is "$1" a whitespace-separated member of "$2"?
contains() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- Validate arguments ----------------------------------------------------
if [[ $# -ne 2 ]]; then
  err "Expected exactly 2 arguments, got $#."
  usage
  exit 1
fi
ENGINE="$1"
ACTION="$2"

if ! contains "${ENGINE}" "${VALID_ENGINES}"; then
  err "Unknown engine: '${ENGINE}'. Valid engines: ${VALID_ENGINES}."
  usage
  exit 1
fi
if ! contains "${ACTION}" "${VALID_ACTIONS}"; then
  err "Unknown action: '${ACTION}'. Valid actions: ${VALID_ACTIONS}."
  usage
  exit 1
fi

# The profile name and the service name both equal the engine name.
SERVICE="${ENGINE}"

# --- Preconditions ---------------------------------------------------------
if [[ ! -f ".env" ]]; then
  err ".env not found. Run ./scripts/setup.sh first, then edit .env."
  exit 1
fi
for f in "${BASE_COMPOSE}" "${DB_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + databases files together, with the engine's profile enabled, so the
# shared `internal` network resolves and only this engine is in scope.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${DB_COMPOSE}" --profile "${ENGINE}")

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    log "Starting '${ENGINE}' (profile: ${ENGINE}) ..."
    "${COMPOSE[@]}" up -d "${SERVICE}"
    "${COMPOSE[@]}" ps "${SERVICE}"
    log "'${ENGINE}' is up — reachable on the internal network as ${SERVICE}."
    ;;
  down)
    # Targeted removal: stop + remove ONLY this container (-s stop, -f no
    # prompt). We deliberately do NOT use `compose down`, which would tear
    # down the whole pi-system project (proxy, management, ...). The named
    # data volume is preserved.
    log "Stopping and removing the '${ENGINE}' container (data volume kept) ..."
    "${COMPOSE[@]}" rm -sf "${SERVICE}"
    log "'${ENGINE}' removed. Its data volume (${SERVICE}_data) was NOT touched."
    ;;
  logs)
    log "Following '${ENGINE}' logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200 "${SERVICE}"
    ;;
  status)
    "${COMPOSE[@]}" ps "${SERVICE}"
    ;;
esac
