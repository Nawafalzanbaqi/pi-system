#!/usr/bin/env bash
# ===========================================================================
# pi-system — authentication stack helper (Keycloak)
# ---------------------------------------------------------------------------
# Start/stop/inspect the authentication stack as a unit: Keycloak together with
# its OWN dedicated PostgreSQL (keycloak-db), defined in
# services/auth/auth.compose.yml. Unlike the databases / db-admin helpers there
# are no profiles here — Keycloak and its DB always come up together — so this
# helper just runs the right `docker compose` command with:
#   * the BASE compose file (so the shared `internal` / `proxy` networks
#     resolve), AND
#   * the auth compose file.
#
# Usage:
#     ./scripts/auth.sh <action>
#
#   <action>  up      start the auth stack (keycloak-db + keycloak, detached)
#             down    stop AND remove ONLY the auth containers (the
#                     keycloak_db_data volume — all identity data — is kept)
#             logs    follow the auth stack's logs (Ctrl-C to stop)
#             status  show the auth containers' status
#
# Examples:
#     ./scripts/auth.sh up
#     ./scripts/auth.sh status
#     ./scripts/auth.sh down
#
# REMINDER: Keycloak is reached only through Caddy, so make sure the proxy is up
# (./scripts/start-proxy.sh) to actually open https://auth.<BASE_DOMAIN>.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[auth]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
AUTH_COMPOSE="services/auth/auth.compose.yml"

# The two services this stack owns (used by the targeted `down`).
SERVICES="keycloak keycloak-db"

VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/auth.sh <action>

  <action>   up | down | logs | status

  up      start the auth stack (keycloak-db + keycloak, detached)
  down    stop and remove ONLY the auth containers (the keycloak_db_data
          volume — all identity data — is kept)
  logs    follow the auth stack's logs (Ctrl-C to stop)
  status  show the auth containers' status

Examples:
  ./scripts/auth.sh up
  ./scripts/auth.sh status
  ./scripts/auth.sh down

Reminder: Keycloak is reached only via Caddy — ensure the proxy is running
(./scripts/start-proxy.sh) to open https://auth.<BASE_DOMAIN>.
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
for f in "${BASE_COMPOSE}" "${AUTH_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + auth files together so the shared `internal` / `proxy` networks
# resolve and Keycloak can both reach its DB and be fronted by Caddy.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${AUTH_COMPOSE}")

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    log "Starting the auth stack (keycloak-db + keycloak) ..."
    warn "Keycloak is JVM-based: first boot re-augments the server and can take"
    warn "a minute or more on a Pi. Watch progress with: ./scripts/auth.sh logs"
    "${COMPOSE[@]}" up -d
    "${COMPOSE[@]}" ps
    # Report the subdomain Caddy fronts it at (BASE_DOMAIN -> localhost default).
    DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
    DOMAIN="${DOMAIN:-localhost}"
    log "Keycloak is starting — once ready, reach it via Caddy at https://auth.${DOMAIN}"
    warn "Make sure Caddy is up (./scripts/start-proxy.sh) to actually open that URL."
    ;;
  down)
    # Targeted removal: stop + remove ONLY the auth containers (-s stop, -f no
    # prompt). We deliberately do NOT use `compose down`, which would tear down
    # the whole pi-system project. The keycloak_db_data volume is preserved.
    log "Stopping and removing the auth containers (keycloak_db_data kept) ..."
    "${COMPOSE[@]}" rm -sf ${SERVICES}
    log "Auth stack removed. Its data volume (keycloak_db_data) was NOT touched."
    ;;
  logs)
    log "Following the auth stack's logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200
    ;;
  status)
    "${COMPOSE[@]}" ps
    ;;
esac
