#!/usr/bin/env bash
# ===========================================================================
# pi-system — secret auditor
# ---------------------------------------------------------------------------
# Audits the current .env and reports problems with the SECRET-type variables
# WITHOUT ever revealing their values. It flags:
#   * empty secrets,
#   * secrets that are non-empty but weak/short (or a common default), and
#   * a HARD check that REDIS_PASSWORD is non-empty — an empty one leaves Redis
#     running UNAUTHENTICATED on the internal network,
#   * a HARD check that N8N_ENCRYPTION_KEY is non-empty — n8n encrypts stored
#     credentials with it; losing/changing it makes them unrecoverable, and
#   * a HARD check that the BACKUP ENCRYPTION key is configured — without it the
#     backup job refuses to run, so there would be NO backups at all.
#   * a TELEGRAM BOT check: if TELEGRAM_BOT_TOKEN is set but TELEGRAM_ALLOWED_IDS
#     is empty, the management bot would accept commands from ANYONE who finds it
#     (an open control channel) — reported as a WARNING.
#
# Severity model:
#   CRITICAL  -> exits NON-ZERO. (REDIS_PASSWORD empty; any secret shorter than
#               the hard floor; any secret matching a common weak/default value.)
#   WARNING   -> reported, but does NOT by itself fail. (An empty secret for a
#               service you may simply not be using; or a secret that is set but
#               shorter than the recommended length.)
#
# Empty (non-Redis) secrets are warnings rather than errors on purpose: the
# platform is on-demand (you only fill in the engine(s)/UI(s) you actually use),
# so a blank password for an unused service is fine — but you MUST set it before
# starting that service.
#
# Usage:
#     ./scripts/check-secrets.sh [--min-length N] [-h|--help]
#
#       --min-length N   Recommended minimum secret length (default: 20).
#   -h, --help           Show this help and exit.
#
# Exit code: 0 if no critical problems, 1 if any critical problem is found.
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[check]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }
ok()   { printf '  \033[0;32m✓\033[0m %s\n' "$*"; }
wrn()  { printf '  \033[0;33m!\033[0m %s\n' "$*"; }
bad()  { printf '  \033[0;31m✗\033[0m %s\n' "$*"; }

ENV_FILE=".env"

# Hard floor: any non-empty secret shorter than this is treated as CRITICAL.
HARD_FLOOR=12
# Recommended minimum (overridable). Set-but-shorter => WARNING.
MIN_LENGTH=20

# Secret-type variables to audit. Keep in sync with .env.example and
# scripts/generate-secrets.sh. The parallel array is a human label used only in
# the "empty (unused service is fine)" hint — never a value.
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
SECRET_SERVICE=(
  "PostgreSQL"
  "MySQL (root)"
  "MySQL (app user)"
  "MongoDB (root)"
  "Redis"
  "pgAdmin"
  "Mongo Express UI"
  "Keycloak DB"
  "Keycloak bootstrap admin"
  "n8n DB"
  "n8n credential encryption"
)

# Common weak / placeholder values that must never ship as real secrets.
WEAK_VALUES=(
  password passw0rd pass 123456 12345678 qwerty admin administrator root
  changeme change-me secret default test redis postgres mysql mongo keycloak
)

usage() {
  cat >&2 <<EOF
Usage: ./scripts/check-secrets.sh [--min-length N]

      --min-length N   Recommended minimum secret length (default: ${MIN_LENGTH}).
  -h, --help           Show this help and exit.

Audits ${ENV_FILE} and reports empty/weak/short secrets without revealing their
values, plus a hard check that REDIS_PASSWORD is non-empty. Exits non-zero if a
critical problem is found. See docs/README.md "Security hardening".
EOF
}

# --- Parse arguments -------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-length)
      if [[ $# -lt 2 ]]; then
        err "--min-length requires a value."
        usage
        exit 1
      fi
      MIN_LENGTH="$2"
      shift 2
      ;;
    --min-length=*)
      MIN_LENGTH="${1#*=}"
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

if ! [[ "${MIN_LENGTH}" =~ ^[0-9]+$ ]] || (( MIN_LENGTH < HARD_FLOOR )); then
  err "Invalid --min-length: '${MIN_LENGTH}'. Must be an integer >= ${HARD_FLOOR}."
  exit 1
fi

# --- Preconditions ---------------------------------------------------------
if [[ ! -f "${ENV_FILE}" ]]; then
  err "${ENV_FILE} not found. Create it first:  ./scripts/generate-secrets.sh"
  exit 1
fi

# --- Helpers ---------------------------------------------------------------
# Extract a value WITHOUT executing the file (never `source` an .env). Returns
# the raw value with surrounding quotes, a trailing CR (CRLF files) and edge
# whitespace stripped. The value is used only to measure length / test against
# the weak list — it is never printed.
get_value() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*${key}=" "${ENV_FILE}" | tail -n1 || true)"
  val="${line#*=}"
  val="${val%$'\r'}"                 # strip trailing CR from CRLF files
  val="${val#"${val%%[![:space:]]*}"}"   # ltrim
  val="${val%"${val##*[![:space:]]}"}"   # rtrim
  # Strip a single pair of matching surrounding quotes, if present.
  if [[ "${val}" == \"*\" && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "${val}" == \'*\' && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "${val}"
}

# Is a (lowercased) value in the weak list?
is_weak_value() {
  local v="${1,,}" w
  for w in "${WEAK_VALUES[@]}"; do
    [[ "${v}" == "${w}" ]] && return 0
  done
  return 1
}

# --- Audit -----------------------------------------------------------------
log "Auditing ${ENV_FILE} (values are never shown). Recommended min length: ${MIN_LENGTH}."
echo

critical=0
warnings=0
passed=0

i=0
for key in "${SECRET_KEYS[@]}"; do
  service="${SECRET_SERVICE[$i]}"
  i=$(( i + 1 ))

  # A missing line is reported distinctly from an empty value.
  if ! grep -qE "^[[:space:]]*${key}=" "${ENV_FILE}"; then
    case "${key}" in
      REDIS_PASSWORD)
        bad "${key}: MISSING from ${ENV_FILE} — Redis would run UNAUTHENTICATED."
        critical=$(( critical + 1 )) ;;
      N8N_ENCRYPTION_KEY)
        bad "${key}: MISSING from ${ENV_FILE} — n8n needs a STABLE key; without it stored credentials become unrecoverable."
        critical=$(( critical + 1 )) ;;
      *)
        wrn "${key}: missing from ${ENV_FILE} (add it before using ${service})."
        warnings=$(( warnings + 1 )) ;;
    esac
    continue
  fi

  value="$(get_value "${key}")"
  len="${#value}"

  if [[ -z "${value}" ]]; then
    case "${key}" in
      REDIS_PASSWORD)
        bad "${key}: EMPTY — Redis would run UNAUTHENTICATED on the internal network."
        critical=$(( critical + 1 )) ;;
      N8N_ENCRYPTION_KEY)
        bad "${key}: EMPTY — set a stable key before starting n8n (generate one with: openssl rand -hex 32)."
        bad "  Losing or changing it later makes every stored n8n credential unrecoverable."
        critical=$(( critical + 1 )) ;;
      *)
        wrn "${key}: empty (OK only if you are not using ${service}; set it before you do)."
        warnings=$(( warnings + 1 )) ;;
    esac
  elif is_weak_value "${value}"; then
    bad "${key}: matches a common weak/default value — replace it."
    critical=$(( critical + 1 ))
  elif (( len < HARD_FLOOR )); then
    bad "${key}: far too short (length ${len}; hard minimum ${HARD_FLOOR})."
    critical=$(( critical + 1 ))
  elif (( len < MIN_LENGTH )); then
    wrn "${key}: shorter than recommended (length ${len}; recommended >= ${MIN_LENGTH})."
    warnings=$(( warnings + 1 ))
  else
    ok "${key}: set, length ${len}."
    passed=$(( passed + 1 ))
  fi

  value=""    # drop the value
done

# --- Backup encryption key (CRITICAL) --------------------------------------
# Encryption isn't a length-checkable secret in .env; it is either a set of age
# recipients OR a git-ignored age identity FILE. A missing key means the backup
# job aborts (it never writes plaintext), i.e. NO backups — so treat it as
# critical, like an unauthenticated Redis.
echo
recips="$(get_value BACKUP_AGE_RECIPIENTS)"
keyfile="$(get_value BACKUP_AGE_KEY_FILE)"
keyfile="${keyfile:-./secrets/backup/age-identity.key}"
case "${keyfile}" in
  /*) keyfile_abs="${keyfile}" ;;
  *)  keyfile_abs="${PROJECT_ROOT}/${keyfile#./}" ;;
esac
if [[ -n "${recips}" ]]; then
  ok "BACKUP_AGE: encryption configured via BACKUP_AGE_RECIPIENTS."
  passed=$(( passed + 1 ))
elif [[ -s "${keyfile_abs}" ]]; then
  ok "BACKUP_AGE: age identity present (${keyfile})."
  passed=$(( passed + 1 ))
else
  bad "BACKUP encryption key MISSING — backups cannot be encrypted (none would be written)."
  bad "  Generate it once with:  ./scripts/backup.sh init-key"
  critical=$(( critical + 1 ))
fi

# --- Telegram management bot (security cross-check) -------------------------
# The bot (automation/workflows/telegram-management-bot.json) is locked to an
# ALLOWLIST of Telegram user ids. A token WITHOUT an allowlist is the dangerous
# case: the bot would accept control commands from anyone who finds it. We never
# print the token; we only test whether each value is empty.
echo
tg_token="$(get_value TELEGRAM_BOT_TOKEN)"
tg_ids="$(get_value TELEGRAM_ALLOWED_IDS)"
tg_ids_stripped="${tg_ids//[[:space:],;]/}"     # blank if only separators/whitespace
if [[ -n "${tg_token}" ]]; then
  if [[ -z "${tg_ids_stripped}" ]]; then
    wrn "TELEGRAM_BOT_TOKEN is set but TELEGRAM_ALLOWED_IDS is EMPTY — the bot would"
    wrn "  accept commands from ANYONE who finds it. Set your numeric Telegram id(s)."
    warnings=$(( warnings + 1 ))
  else
    ok "TELEGRAM bot: token set with a non-empty allowlist."
    passed=$(( passed + 1 ))
  fi
elif [[ -n "${tg_ids_stripped}" ]]; then
  wrn "TELEGRAM_ALLOWED_IDS is set but TELEGRAM_BOT_TOKEN is empty — the bot is inactive."
  warnings=$(( warnings + 1 ))
fi

# --- Summary ---------------------------------------------------------------
echo
log "Summary: ${passed} OK, ${warnings} warning(s), ${critical} critical."

if (( critical > 0 )); then
  err "Critical secret problems found — fix these before exposing the platform."
  err "Generate strong values with:  ./scripts/generate-secrets.sh --force"
  exit 1
fi

if (( warnings > 0 )); then
  warn "No critical problems, but review the warnings above."
fi

log "No critical secret problems found."
exit 0
