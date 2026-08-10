#!/usr/bin/env bash
# ===========================================================================
# pi-system — local package cache helper (npm + NuGet)
# ---------------------------------------------------------------------------
# Start/stop/inspect the OPTIONAL package cache as a unit: Verdaccio (local npm
# registry/cache) + nuget-cache (BaGetter, NuGet mirror), defined in
# services/cache/cache.compose.yml behind the Compose PROFILE "cache" (so they
# never auto-start and use no RAM until you bring them up).
#
# Like the other helpers it just runs the right `docker compose` command with:
#   * the BASE compose file (so the shared `internal` / `proxy` networks
#     resolve), AND
#   * the cache compose file, AND
#   * --profile cache (required, since the services are profile-gated).
#
# Usage:
#     ./scripts/cache.sh <action>
#
#   <action>  up      start the package cache (verdaccio + nuget-cache, detached)
#             down    stop AND remove ONLY the cache containers (the cached
#                     packages — verdaccio_storage + nuget_cache_data volumes —
#                     are KEPT)
#             logs    follow the cache's logs (Ctrl-C to stop)
#             status  show the cache containers' status
#
# Examples:
#     ./scripts/cache.sh up
#     ./scripts/cache.sh status
#     ./scripts/cache.sh down
#
# A project OPTS IN to the cache (it is never forced) — see
# services/cache/README.md and docs/README.md "Package cache".
#
# REMINDER: Verdaccio's UI is reached only through Caddy, so make sure the proxy
# is up (./scripts/start-proxy.sh) to open https://cache.<BASE_DOMAIN>. The npm
# and NuGet endpoints themselves are reached over the `internal` network and do
# NOT need Caddy.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[cache]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
CACHE_COMPOSE="services/cache/cache.compose.yml"

# The two services this stack owns (used by the targeted `down`).
SERVICES="verdaccio nuget-cache"
PROFILE="cache"

VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/cache.sh <action>

  <action>   up | down | logs | status

  up      start the package cache (verdaccio + nuget-cache, detached)
  down    stop and remove ONLY the cache containers (the cached packages —
          verdaccio_storage and nuget_cache_data volumes — are kept)
  logs    follow the cache's logs (Ctrl-C to stop)
  status  show the cache containers' status

Examples:
  ./scripts/cache.sh up
  ./scripts/cache.sh status
  ./scripts/cache.sh down

A project opts in to the cache (never forced) — see services/cache/README.md.
Verdaccio's UI is reached via Caddy — ensure the proxy is running
(./scripts/start-proxy.sh) to open https://cache.<BASE_DOMAIN>.
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
for f in "${BASE_COMPOSE}" "${CACHE_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + cache files together, with the `cache` profile enabled, so the shared
# `internal` / `proxy` networks resolve and the profile-gated services are in
# scope. --project-directory is pinned to the root so the relative verdaccio
# config bind-mount resolves.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${CACHE_COMPOSE}" --profile "${PROFILE}")

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    log "Starting the package cache (verdaccio + nuget-cache, profile: ${PROFILE}) ..."
    warn "First boot pulls the two images and BaGetter initialises its store —"
    warn "give it a moment. Watch progress with: ./scripts/cache.sh logs"
    "${COMPOSE[@]}" up -d
    "${COMPOSE[@]}" ps
    DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
    DOMAIN="${DOMAIN:-localhost}"
    log "Cache is up:"
    log "  npm   -> http://verdaccio:4873/                  (UI: https://cache.${DOMAIN})"
    log "  NuGet -> http://nuget-cache:8080/v3/index.json   (internal only)"
    log "Projects opt in via './scripts/new-project.sh ... --cache' or the env/CLI"
    log "method in services/cache/README.md. The cache is reached on the 'internal'"
    log "network — see the build-network note in docs/README.md \"Package cache\"."
    warn "For the UI, make sure Caddy is up (./scripts/start-proxy.sh)."
    ;;
  down)
    # Targeted removal: stop + remove ONLY the cache containers (-s stop, -f no
    # prompt). We deliberately do NOT use `compose down`, which would tear down
    # the whole pi-system project. The cached-package volumes are preserved.
    log "Stopping and removing the cache containers (cached packages kept) ..."
    "${COMPOSE[@]}" rm -sf ${SERVICES}
    log "Cache removed. Its volumes (verdaccio_storage, nuget_cache_data) were NOT touched."
    ;;
  logs)
    log "Following the cache's logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200
    ;;
  status)
    "${COMPOSE[@]}" ps
    ;;
esac
