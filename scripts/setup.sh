#!/usr/bin/env bash
# ===========================================================================
# pi-system — setup / bootstrap script
# ---------------------------------------------------------------------------
# Idempotent. Safe to run repeatedly. It will:
#   1. Verify Docker is installed.
#   2. Verify Docker Compose v2 (the `docker compose` plugin) is available.
#   3. Create the local data/ and secrets/ directories if missing.
#   4. Create .env from .env.example on first run (never overwrites).
#   5. Validate the base compose file.
#
# Run from anywhere — paths are resolved relative to the project root:
#     ./scripts/setup.sh
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[setup]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m  %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

COMPOSE_FILE="infrastructure/docker-compose.yml"

# --- 1. Docker -------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  err "Docker is not installed or not on PATH."
  err "Install it first:  curl -fsSL https://get.docker.com | sh"
  exit 1
fi
log "Docker found: $(docker --version)"

# --- 2. Docker Compose v2 --------------------------------------------------
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available (the 'docker compose' plugin is missing)."
  err "On Debian/Raspberry Pi OS:  sudo apt-get install -y docker-compose-plugin"
  exit 1
fi
log "Docker Compose found: $(docker compose version --short)"

# --- 3. Create data / secrets directories ----------------------------------
for d in data secrets; do
  if [[ -d "${d}" ]]; then
    log "Directory already exists: ${d}/"
  else
    mkdir -p "${d}"
    log "Created directory: ${d}/"
  fi
done

# --- 4. Create .env from the template --------------------------------------
if [[ -f ".env" ]]; then
  log ".env already exists — leaving it untouched."
elif [[ -f ".env.example" ]]; then
  cp ".env.example" ".env"
  log "Created .env from .env.example."
  warn "Edit .env and fill in your values before bringing the stack up."
else
  err ".env.example is missing; cannot create .env."
  exit 1
fi

# --- 5. Validate the base compose file -------------------------------------
if docker compose --env-file .env -f "${COMPOSE_FILE}" config >/dev/null 2>&1; then
  log "Base compose file is valid: ${COMPOSE_FILE}"
else
  warn "Could not validate ${COMPOSE_FILE} (check Docker permissions / .env)."
fi

log "Setup complete."
log "Next step: edit .env, then start the base networks/services with:"
log "  docker compose --env-file .env -f ${COMPOSE_FILE} up -d"
