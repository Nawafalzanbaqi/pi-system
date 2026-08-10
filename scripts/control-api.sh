#!/usr/bin/env bash
# ===========================================================================
# pi-system — Control API helper (the secure web-control-panel backend)
# ---------------------------------------------------------------------------
# Start/stop/inspect the API-only Control API service defined in
# services/control-api/control-api.compose.yml. Like the other helpers it just
# runs the right `docker compose` command with the BASE compose file (so the
# shared `internal` / `proxy` networks resolve) and the control-api compose file.
# The service has NO host ports and is reached only via Caddy at api.<BASE_DOMAIN>.
#
# Usage:
#     ./scripts/control-api.sh <action>
#
#   <action>  up      build + start the control-api (detached)
#             down    stop AND remove ONLY the control-api container
#             logs    follow the control-api logs (Ctrl-C to stop)
#             status  show the control-api container's status
#
# This is also the target of the bot-exec `restart control-api` action (down+up).
#
# DEFERRED one-time setup before it can authenticate / control the host:
#   1. Keycloak: create a client for the control panel; set CONTROL_API_OIDC_*
#      in .env and assign the operator role to yourself.
#   2. SSH bridge: generate a dedicated key under ./secrets/control-api/bridge_key,
#      add its PUBLIC half to the host authorized_keys pinned to the bot-exec
#      forced command, and set CONTROL_API_BRIDGE_SSH_HOST/USER in .env.
#   See docs/README.md "Control API".
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[control-api]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
CONTROL_API_COMPOSE="services/control-api/control-api.compose.yml"

SERVICES="control-api"
VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/control-api.sh <action>

  <action>   up | down | logs | status

  up      build + start the control-api (detached)
  down    stop and remove ONLY the control-api container
  logs    follow the control-api logs (Ctrl-C to stop)
  status  show the control-api container's status

The Control API is reached via Caddy at https://api.<BASE_DOMAIN> — ensure the
proxy is up (./scripts/start-proxy.sh). See docs/README.md "Control API" for the
deferred Keycloak client + SSH bridge setup.
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
for f in "${BASE_COMPOSE}" "${CONTROL_API_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + control-api files together, so the shared `internal` / `proxy` networks
# resolve. --project-directory is pinned to the root for consistency with the
# other helpers (and so the ./:/workspace bind mount resolves to the repo root).
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${CONTROL_API_COMPOSE}")

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    log "Building + starting the control-api ..."
    "${COMPOSE[@]}" up -d --build
    "${COMPOSE[@]}" ps
    DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
    DOMAIN="${DOMAIN:-localhost}"
    log "Control API is up:"
    log "  base URL  -> https://api.${DOMAIN}"
    log "  liveness  -> https://api.${DOMAIN}/api/health   (public)"
    warn "All other endpoints require a Keycloak token; writes/actions need the"
    warn "operator role. Configure CONTROL_API_OIDC_* and the SSH bridge in .env"
    warn "(see docs/README.md \"Control API\"). Ensure Caddy is up (./scripts/start-proxy.sh)."
    ;;
  down)
    log "Stopping and removing the control-api container ..."
    "${COMPOSE[@]}" rm -sf ${SERVICES}
    log "Control API removed."
    ;;
  logs)
    log "Following the control-api logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200
    ;;
  status)
    "${COMPOSE[@]}" ps
    ;;
esac
