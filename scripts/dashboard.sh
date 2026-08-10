#!/usr/bin/env bash
# ===========================================================================
# pi-system — dashboard helper (Homepage)
# ---------------------------------------------------------------------------
# Start/stop/inspect the unified dashboard (Homepage), defined in
# services/dashboard/dashboard.compose.yml. Like the auth / automation helpers
# there are no profiles here — the dashboard is a single service — so this
# helper just runs the right `docker compose` command with:
#   * the BASE compose file (so the shared `internal` / `proxy` networks
#     resolve), AND
#   * the dashboard compose file.
#
# It also pins --project-directory to the project root so the dashboard's
# RELATIVE config bind-mount (./services/dashboard/config) resolves correctly,
# exactly like the proxy helper does for the Caddyfile.
#
# Usage:
#     ./scripts/dashboard.sh <action>
#
#   <action>  up      start the dashboard (Homepage, detached)
#             down    stop AND remove ONLY the dashboard container (the
#                     committed config under services/dashboard/config is on
#                     disk and is never touched)
#             logs    follow the dashboard's logs (Ctrl-C to stop)
#             status  show the dashboard container's status
#
# Examples:
#     ./scripts/dashboard.sh up
#     ./scripts/dashboard.sh status
#     ./scripts/dashboard.sh down
#
# REMINDER: Homepage is reached only through Caddy, so make sure the proxy is up
# (./scripts/start-proxy.sh) to actually open https://home.<BASE_DOMAIN>.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[dashboard]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
DASHBOARD_COMPOSE="services/dashboard/dashboard.compose.yml"

# The single service this stack owns (used by the targeted `down`).
SERVICES="homepage"

VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/dashboard.sh <action>

  <action>   up | down | logs | status

  up      start the dashboard (Homepage, detached)
  down    stop and remove ONLY the dashboard container (the committed config
          under services/dashboard/config is never touched)
  logs    follow the dashboard's logs (Ctrl-C to stop)
  status  show the dashboard container's status

Examples:
  ./scripts/dashboard.sh up
  ./scripts/dashboard.sh status
  ./scripts/dashboard.sh down

Reminder: Homepage is reached only via Caddy — ensure the proxy is running
(./scripts/start-proxy.sh) to open https://home.<BASE_DOMAIN>.
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
for f in "${BASE_COMPOSE}" "${DASHBOARD_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + dashboard files together so the shared `internal` / `proxy` networks
# resolve (Homepage needs `internal` to probe the other services and `proxy` to
# be fronted by Caddy). --project-directory pins the root so the relative config
# bind-mount in the compose file resolves.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${DASHBOARD_COMPOSE}")

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    log "Starting the dashboard (Homepage) ..."
    "${COMPOSE[@]}" up -d
    "${COMPOSE[@]}" ps
    # Report the subdomain Caddy fronts it at (BASE_DOMAIN -> localhost default).
    DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
    DOMAIN="${DOMAIN:-localhost}"
    log "Dashboard is starting — reach it via Caddy at https://home.${DOMAIN}"
    warn "Make sure Caddy is up (./scripts/start-proxy.sh) to actually open that URL."
    ;;
  down)
    # Targeted removal: stop + remove ONLY the dashboard container (-s stop, -f
    # no prompt). We deliberately do NOT use `compose down`, which would tear
    # down the whole pi-system project. The committed config on disk is kept.
    log "Stopping and removing the dashboard container (config on disk kept) ..."
    "${COMPOSE[@]}" rm -sf ${SERVICES}
    log "Dashboard removed. Its config (services/dashboard/config) was NOT touched."
    ;;
  logs)
    log "Following the dashboard's logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200
    ;;
  status)
    "${COMPOSE[@]}" ps
    ;;
esac
