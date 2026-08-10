#!/usr/bin/env bash
# ===========================================================================
# pi-system — start the reverse proxy (and what it fronts)
# ---------------------------------------------------------------------------
# Brings up Caddy together with the base networks and the management stack, so
# the shared `proxy` network exists AND the upstreams Caddy routes to
# (Portainer, Uptime Kuma) are running. Three compose files are merged:
#   base       — defines the `internal` / `proxy` networks
#   management — Portainer, Uptime Kuma, Watchtower
#   proxy      — Caddy (this phase)
#
# --project-directory is pinned to the project root so the relative Caddyfile
# bind-mount in proxy.compose.yml (./services/proxy/Caddyfile) resolves no
# matter which compose file is listed first.
#
# Run from anywhere — paths resolve relative to the project root:
#     ./scripts/start-proxy.sh
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[proxy]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
MGMT_COMPOSE="infrastructure/management.compose.yml"
PROXY_COMPOSE="services/proxy/proxy.compose.yml"

# --- Preconditions ---------------------------------------------------------
if [[ ! -f ".env" ]]; then
  err ".env not found. Run ./scripts/setup.sh first, then edit .env."
  exit 1
fi
for f in "${BASE_COMPOSE}" "${MGMT_COMPOSE}" "${PROXY_COMPOSE}" "services/proxy/Caddyfile"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing required file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# All three files together; project dir pinned to root for path resolution.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${MGMT_COMPOSE}" -f "${PROXY_COMPOSE}")

# --- Validate, then bring up ----------------------------------------------
log "Validating merged compose configuration..."
if ! "${COMPOSE[@]}" config >/dev/null; then
  err "Compose validation failed. Check .env and the three compose files."
  exit 1
fi

log "Starting reverse proxy + management stack (Caddy, Portainer, Uptime Kuma, Watchtower)..."
"${COMPOSE[@]}" up -d

log "Current status:"
"${COMPOSE[@]}" ps

# --- Report how to reach the UIs -------------------------------------------
DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
DOMAIN="${DOMAIN:-localhost}"
log "Done. Caddy fronts the UIs over HTTPS:"
log "  Portainer  ->  https://portainer.${DOMAIN}"
log "  Uptime Kuma -> https://status.${DOMAIN}"
log "With no ACME_EMAIL set, Caddy serves locally-trusted certs from its"
log "internal CA. Export its root to trust it on other machines:"
log "  ${COMPOSE[*]} cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt"
