#!/usr/bin/env bash
# ===========================================================================
# pi-system — web analytics helper (Umami)
# ---------------------------------------------------------------------------
# Start/stop/inspect the OPTIONAL, self-hosted, privacy-first analytics engine as
# a unit: Umami (the app) + umami-db (its dedicated, isolated PostgreSQL), defined
# in services/analytics/analytics.compose.yml behind the Compose PROFILE
# "analytics" (so they never auto-start and use no RAM until you bring them up).
#
# Like the other helpers it just runs the right `docker compose` command with:
#   * the BASE compose file (so the shared `internal` / `proxy` networks
#     resolve), AND
#   * the analytics compose file, AND
#   * --profile analytics (required, since the services are profile-gated).
#
# Usage:
#     ./scripts/analytics.sh <action>
#
#   <action>  up      start analytics (umami + umami-db, detached)
#             down    stop AND remove ONLY the analytics containers (the collected
#                     analytics — the umami_db_data volume — is KEPT)
#             logs    follow the analytics logs (Ctrl-C to stop)
#             status  show the analytics containers' status
#
# Examples:
#     ./scripts/analytics.sh up
#     ./scripts/analytics.sh status
#     ./scripts/analytics.sh down
#
# A generated project OPTS IN to analytics via the `web-analytics` module (it is
# never forced) — see templates/modules/web-analytics/README.md and docs/README.md
# "Web analytics".
#
# REMINDER: the Umami dashboard is reached only through Caddy, so make sure the
# proxy is up (./scripts/start-proxy.sh) to open https://analytics.<BASE_DOMAIN>.
# First boot creates a default admin (admin / umami) — CHANGE that password right
# after the first login.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[analytics]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
ANALYTICS_COMPOSE="services/analytics/analytics.compose.yml"

# The two services this stack owns (used by the targeted `down`).
SERVICES="umami umami-db"
PROFILE="analytics"

VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/analytics.sh <action>

  <action>   up | down | logs | status

  up      start analytics (umami + umami-db, detached)
  down    stop and remove ONLY the analytics containers (the collected analytics —
          the umami_db_data volume — is kept)
  logs    follow the analytics logs (Ctrl-C to stop)
  status  show the analytics containers' status

Examples:
  ./scripts/analytics.sh up
  ./scripts/analytics.sh status
  ./scripts/analytics.sh down

A project opts in to analytics via the web-analytics module (never forced) — see
templates/modules/web-analytics/README.md. The Umami dashboard is reached via Caddy
— ensure the proxy is running (./scripts/start-proxy.sh) to open
https://analytics.<BASE_DOMAIN>.
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
for f in "${BASE_COMPOSE}" "${ANALYTICS_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + analytics files together, with the `analytics` profile enabled, so the
# shared `internal` / `proxy` networks resolve and the profile-gated services are
# in scope. --project-directory is pinned to the root for consistency with the
# other helpers.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${ANALYTICS_COMPOSE}" --profile "${PROFILE}")

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    log "Starting web analytics (umami + umami-db, profile: ${PROFILE}) ..."
    warn "First boot pulls the two images and Umami runs its migrations + seeds the"
    warn "default admin — give it a moment. Watch progress with: ./scripts/analytics.sh logs"
    "${COMPOSE[@]}" up -d
    "${COMPOSE[@]}" ps
    DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
    DOMAIN="${DOMAIN:-localhost}"
    log "Analytics is up:"
    log "  dashboard -> https://analytics.${DOMAIN}   (login: admin / umami — CHANGE it)"
    log "  tracker   -> https://analytics.${DOMAIN}/script.js   (loaded by your sites)"
    log "Point a project at it with the 'web-analytics' module — see"
    log "templates/modules/web-analytics/README.md and docs/README.md \"Web analytics\"."
    warn "For the dashboard, make sure Caddy is up (./scripts/start-proxy.sh)."
    ;;
  down)
    # Targeted removal: stop + remove ONLY the analytics containers (-s stop, -f no
    # prompt). We deliberately do NOT use `compose down`, which would tear down the
    # whole pi-system project. The collected-analytics volume is preserved.
    log "Stopping and removing the analytics containers (collected analytics kept) ..."
    "${COMPOSE[@]}" rm -sf ${SERVICES}
    log "Analytics removed. Its volume (umami_db_data) was NOT touched."
    ;;
  logs)
    log "Following the analytics logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200
    ;;
  status)
    "${COMPOSE[@]}" ps
    ;;
esac
