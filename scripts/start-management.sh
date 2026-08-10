#!/usr/bin/env bash
# ===========================================================================
# pi-system — start the management & monitoring stack
# ---------------------------------------------------------------------------
# Brings up ONLY the management layer (Portainer, Uptime Kuma, Watchtower).
# The base compose file is passed alongside the management one so the shared
# `internal` / `proxy` networks are inherited (the base file defines them).
#
# Run from anywhere — paths resolve relative to the project root:
#     ./scripts/start-management.sh
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[management]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m       %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m      %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
MGMT_COMPOSE="infrastructure/management.compose.yml"

# --- Preconditions ---------------------------------------------------------
if [[ ! -f ".env" ]]; then
  err ".env not found. Run ./scripts/setup.sh first, then edit .env."
  exit 1
fi
for f in "${BASE_COMPOSE}" "${MGMT_COMPOSE}"; do
  if [[ ! -f "${f}" ]]; then
    err "Missing compose file: ${f}"
    exit 1
  fi
done
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Both files together: base supplies the networks, management the services.
COMPOSE=(docker compose --env-file .env -f "${BASE_COMPOSE}" -f "${MGMT_COMPOSE}")

# --- Validate, then bring up ----------------------------------------------
log "Validating merged compose configuration..."
if ! "${COMPOSE[@]}" config >/dev/null; then
  err "Compose validation failed. Check .env and the two compose files."
  exit 1
fi

log "Starting management stack (Portainer, Uptime Kuma, Watchtower)..."
"${COMPOSE[@]}" up -d

log "Current status:"
"${COMPOSE[@]}" ps

log "Done."
log "Watchtower is NOTIFY-ONLY: it reports image updates on its weekly"
log "schedule and never auto-updates containers. Inspect it with:"
log "  ${COMPOSE[*]} logs watchtower"
