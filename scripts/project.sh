#!/usr/bin/env bash
# ===========================================================================
# pi-system — generated-project helper
# ---------------------------------------------------------------------------
# Start/stop/inspect a project created by scripts/new-project.sh. Each project
# lives in services/<name>/ with its own compose fragment <name>.compose.yml.
# This helper just runs the right `docker compose` command with:
#   * the BASE compose file (so the shared `internal` / `proxy` networks
#     resolve), AND
#   * the project's compose fragment.
#
# Usage:
#     ./scripts/project.sh <action> <project-name>
#
#   <action>  up      build (if needed) and start the project (detached)
#             down    stop AND remove ONLY this project's container(s)
#                     (the shared networks and other stacks are untouched)
#             logs    follow this project's logs (Ctrl-C to stop)
#             status  show this project's container status
#
# Examples:
#     ./scripts/project.sh up acme-portal
#     ./scripts/project.sh logs acme-portal
#     ./scripts/project.sh down acme-portal
#
# Reminders: the project is reached only via Caddy (./scripts/start-proxy.sh),
# and if it uses a database, start that first (./scripts/db.sh <engine> up).
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[project]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
VALID_ACTIONS="up down logs status"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/project.sh <action> <project-name>

  <action>        up | down | logs | status
  <project-name>  a project created by ./scripts/new-project.sh

  up      build (if needed) and start the project (detached)
  down    stop and remove ONLY this project's container(s) (networks kept)
  logs    follow this project's logs (Ctrl-C to stop)
  status  show this project's container status

Examples:
  ./scripts/project.sh up acme-portal
  ./scripts/project.sh down acme-portal
EOF
}

# Is "\$1" a whitespace-separated member of "\$2"?
contains() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- Validate arguments ----------------------------------------------------
if [[ $# -ne 2 ]]; then
  err "Expected exactly 2 arguments, got $#."
  usage
  exit 1
fi
ACTION="$1"
NAME="$2"

if ! contains "${ACTION}" "${VALID_ACTIONS}"; then
  err "Unknown action: '${ACTION}'. Valid actions: ${VALID_ACTIONS}."
  usage
  exit 1
fi
if ! [[ "${NAME}" =~ ^[a-z][a-z0-9-]{0,38}[a-z0-9]$ ]]; then
  err "Invalid project name: '${NAME}'."
  exit 1
fi

PROJECT_DIR="${SERVICES_DIR:-services}/${NAME}"
FRAGMENT="${PROJECT_DIR}/${NAME}.compose.yml"

# --- Preconditions ---------------------------------------------------------
if [[ ! -f ".env" ]]; then
  err ".env not found. Run ./scripts/setup.sh first, then edit .env."
  exit 1
fi
if [[ ! -f "${FRAGMENT}" ]]; then
  err "Project '${NAME}' not found (missing ${FRAGMENT})."
  err "Create it first:  ./scripts/new-project.sh --name ${NAME} --template <t> --db <engine> --subdomain <sub>"
  exit 1
fi
if [[ ! -f "${BASE_COMPOSE}" ]]; then
  err "Missing required file: ${BASE_COMPOSE}"
  exit 1
fi
if ! docker compose version >/dev/null 2>&1; then
  err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
  exit 1
fi

# Base + the project fragment together; project dir pinned to root so the
# fragment's relative build context (./services/<name>) resolves correctly.
COMPOSE=(docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${FRAGMENT}")

# Also load any module compose fragments the generator added for this project
# (services/<name>/<name>.<module>.compose.yml). The pattern does NOT match the
# main fragment (<name>.compose.yml), so existing single-fragment projects are
# unaffected.
shopt -s nullglob
for extra in "${PROJECT_DIR}/${NAME}".*.compose.yml; do
  COMPOSE+=(-f "${extra}")
  log "Including module fragment: ${extra##*/}"
done
shopt -u nullglob

# Read the project's metadata (subdomain + db) embedded by new-project.sh.
SUBDOMAIN="$(grep -E '^# pi-system-subdomain:' "${FRAGMENT}" | head -n1 | awk '{print $3}')"
DBENGINE="$(grep -E '^# pi-system-db:' "${FRAGMENT}" | head -n1 | awk '{print $3}')"
DOMAIN="$(grep -E '^BASE_DOMAIN=' .env | cut -d= -f2-)"
DOMAIN="${DOMAIN:-localhost}"

# --- Dispatch --------------------------------------------------------------
case "${ACTION}" in
  up)
    if [[ -n "${DBENGINE}" && "${DBENGINE}" != "none" ]]; then
      warn "This project uses the '${DBENGINE}' database — start it first if needed:"
      warn "  ./scripts/db.sh ${DBENGINE} up"
    fi
    warn "It is reachable only via Caddy — ensure the proxy is up (./scripts/start-proxy.sh)."
    log "Building and starting '${NAME}' ..."
    "${COMPOSE[@]}" up -d --build
    "${COMPOSE[@]}" ps
    if [[ -n "${SUBDOMAIN}" ]]; then
      log "'${NAME}' is up — reach it at https://${SUBDOMAIN}.${DOMAIN}"
    else
      log "'${NAME}' is up."
    fi
    ;;
  down)
    # Targeted removal: stop + remove ONLY this project's container(s). The base
    # file defines NO services, so this scope is exactly this project — we never
    # use `compose down`, which would tear down the shared networks/other stacks.
    log "Stopping and removing '${NAME}' container(s) ..."
    "${COMPOSE[@]}" rm -sf
    log "'${NAME}' removed. Shared networks and other stacks were NOT touched."
    ;;
  logs)
    log "Following '${NAME}' logs (Ctrl-C to stop) ..."
    "${COMPOSE[@]}" logs -f --tail=200
    ;;
  status)
    "${COMPOSE[@]}" ps
    ;;
esac
