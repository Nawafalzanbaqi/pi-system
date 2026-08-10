#!/usr/bin/env bash
# ===========================================================================
# pi-system — secret generator
# ---------------------------------------------------------------------------
# Generates strong, cryptographically-random values (via `openssl rand`) for
# every SECRET-type variable the platform needs, and writes a populated .env
# from .env.example. Non-secret values (usernames, db names, domains, network
# names, ...) are intentionally LEFT BLANK for you to fill in afterwards — this
# script only deals with passwords/credentials.
#
# Secrets filled (the password / key fields from .env.example):
#   POSTGRES_PASSWORD            MYSQL_ROOT_PASSWORD        MYSQL_PASSWORD
#   MONGO_INITDB_ROOT_PASSWORD   REDIS_PASSWORD             PGADMIN_DEFAULT_PASSWORD
#   ME_CONFIG_BASICAUTH_PASSWORD KC_DB_PASSWORD             KC_BOOTSTRAP_ADMIN_PASSWORD
#   N8N_DB_PASSWORD              N8N_ENCRYPTION_KEY
# This list is kept in lock-step with scripts/check-secrets.sh (a test cross-checks
# the two so neither can silently drift). The age BACKUP key is NOT here — it is a
# separate one-time step: ./scripts/backup.sh init-key.
#
# SAFETY:
#   * It will NOT overwrite an existing .env unless you pass --force, and even
#     then it first makes a timestamped backup (.env.bak.<timestamp>, git-ignored).
#   * Generated secrets are NEVER printed — the script only reports WHICH keys
#     were filled, never their values. The real values live only in .env.
#
# Usage:
#     ./scripts/generate-secrets.sh [--force] [--length N] [-h|--help]
#
#   -f, --force      Overwrite an existing .env (a backup is made first).
#       --length N   Length of each generated secret (default: 40; min 16).
#   -h, --help       Show this help and exit.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[secrets]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

TEMPLATE=".env.example"
ENV_FILE=".env"

# Secret-type variables to generate. Keep this list in sync with .env.example
# and with scripts/check-secrets.sh.
SECRET_KEYS=(
  POSTGRES_PASSWORD
  MYSQL_ROOT_PASSWORD
  MYSQL_PASSWORD
  MONGO_INITDB_ROOT_PASSWORD
  REDIS_PASSWORD
  PGADMIN_DEFAULT_PASSWORD
  ME_CONFIG_BASICAUTH_PASSWORD
  KC_DB_PASSWORD
  KC_BOOTSTRAP_ADMIN_PASSWORD
  N8N_DB_PASSWORD
  N8N_ENCRYPTION_KEY
)

usage() {
  cat >&2 <<EOF
Usage: ./scripts/generate-secrets.sh [--force] [--length N]

  -f, --force      Overwrite an existing .env (a timestamped backup is made first).
      --length N   Length of each generated secret (default: 40; minimum 16).
  -h, --help       Show this help and exit.

Generates strong random values for every secret-type variable and writes a
populated .env from .env.example. Non-secret values are left blank for you to
fill in. Generated secrets are never printed. See docs/README.md.
EOF
}

# --- Parse arguments -------------------------------------------------------
FORCE=0
SECRET_LENGTH=40

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--force)
      FORCE=1
      shift
      ;;
    --length)
      if [[ $# -lt 2 ]]; then
        err "--length requires a value."
        usage
        exit 1
      fi
      SECRET_LENGTH="$2"
      shift 2
      ;;
    --length=*)
      SECRET_LENGTH="${1#*=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      err "Unknown argument: '$1'."
      usage
      exit 1
      ;;
  esac
done

if ! [[ "${SECRET_LENGTH}" =~ ^[0-9]+$ ]] || (( SECRET_LENGTH < 16 )); then
  err "Invalid --length: '${SECRET_LENGTH}'. Must be an integer >= 16."
  exit 1
fi

# --- Preconditions ---------------------------------------------------------
if ! command -v openssl >/dev/null 2>&1; then
  err "openssl is not installed or not on PATH (needed for secure randomness)."
  err "Install it first:  sudo apt-get install -y openssl"
  exit 1
fi

if [[ ! -f "${TEMPLATE}" ]]; then
  err "Template ${TEMPLATE} not found — cannot generate ${ENV_FILE}."
  exit 1
fi

# Refuse to clobber an existing .env unless explicitly forced (back up first).
if [[ -f "${ENV_FILE}" ]]; then
  if [[ "${FORCE}" -ne 1 ]]; then
    err "${ENV_FILE} already exists. Refusing to overwrite it."
    err "Re-run with --force to regenerate it from ${TEMPLATE} (a backup is kept)."
    exit 1
  fi
  BACKUP="${ENV_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "${ENV_FILE}" "${BACKUP}"
  warn "Existing ${ENV_FILE} backed up to ${BACKUP} (git-ignored)."
  warn "Note: --force regenerates from ${TEMPLATE}, so any non-secret values you"
  warn "had set (usernames, BASE_DOMAIN, ...) are reset to blank — copy them back"
  warn "from the backup if needed."
fi

# --- Secret generation -----------------------------------------------------
# Cryptographically-sound randomness from openssl. We base64-encode plenty of
# random bytes, strip everything except [A-Za-z0-9] (so the value is safe inside
# .env, shell, and URL/connection strings — no /, +, =, quoting headaches), then
# take the requested number of characters.
gen_secret() {
  local length="$1" raw
  raw="$(openssl rand -base64 $(( length * 2 + 32 )) | LC_ALL=C tr -dc 'A-Za-z0-9')"
  if (( ${#raw} < length )); then
    err "Could not generate enough random characters; please retry."
    exit 1
  fi
  printf '%s' "${raw:0:length}"
}

# Set KEY=value for an existing "KEY=" line in ${ENV_FILE}; append if missing.
# value is alphanumeric only, so it is safe in the sed replacement.
set_secret() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "${ENV_FILE}"; then
    sed -i -E "s|^(${key})=.*\$|\1=${value}|" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" >>"${ENV_FILE}"
  fi
}

# --- Generate --------------------------------------------------------------
# Start from the committed template so structure and comments are preserved.
cp "${TEMPLATE}" "${ENV_FILE}"
log "Created ${ENV_FILE} from ${TEMPLATE}."

filled=0
for key in "${SECRET_KEYS[@]}"; do
  value="$(gen_secret "${SECRET_LENGTH}")"
  set_secret "${key}" "${value}"
  value=""              # drop the value from memory immediately
  log "Filled ${key}"
  filled=$(( filled + 1 ))
done

# Best-effort: keep the generated .env readable only by its owner.
chmod 600 "${ENV_FILE}" 2>/dev/null || warn "Could not chmod 600 ${ENV_FILE} (check permissions)."

echo
log "Done: filled ${filled} secret(s) into ${ENV_FILE} (values not shown)."
warn "Non-secret values were left BLANK. Edit ${ENV_FILE} to set usernames,"
warn "database names, BASE_DOMAIN, network names, etc. before bringing services up."
log "Then audit with:  ./scripts/check-secrets.sh"
