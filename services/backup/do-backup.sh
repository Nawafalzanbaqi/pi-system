#!/usr/bin/env bash
# ===========================================================================
# pi-system — in-container backup orchestrator
# ---------------------------------------------------------------------------
# Runs INSIDE the backup toolbox container (see services/backup/Dockerfile),
# launched on demand by scripts/backup.sh (`docker compose run --rm backup`).
# It connects to each database BY SERVICE NAME on the internal network using the
# credentials from the root .env (mounted via env_file), dumps every engine that
# is currently running with that engine's PROPER tool, encrypts each artifact
# with `age`, and applies retention. Nothing is ever written in plaintext.
#
# Backed up (only the engines that are actually UP are touched):
#   * PostgreSQL  (postgres:5432)        -> pg_dumpall  -> pg.postgres.sql.gz.age
#   * Keycloak DB (keycloak-db:5432)     -> pg_dumpall  -> pg.keycloak-db.sql.gz.age
#   * MySQL       (mysql:3306)           -> mysqldump   -> mysql.<db>.sql.gz.age
#   * MongoDB     (mongo:27017)          -> mongodump   -> mongo.<db>.archive.gz.age
#   * Redis       (redis:6379)           -> redis-cli --rdb -> redis.dump.rdb.gz.age
#   * Extra DBs   (BACKUP_EXTRA_TARGETS) -> per engine  -> pg./mysql./mongo. ...
#   * Config      (/project, ro)         -> tar+gzip    -> config.tar.gz.age
#
# Layout written under $BACKUPS_DIR (default /backups -> host ./data/backups):
#   daily/<TS>/<artifacts...> + manifest.txt
#   weekly/<WEEK>__<TS>/<artifacts...>   (one promoted run per ISO week)
#   status/last-backup.json + backup.log
#
# Exit code: 0 if every ATTEMPTED dump succeeded (engines that are down are
# SKIPPED, not failures); non-zero if any attempted dump or the config archive
# failed, or if encryption is not configured (in which case it aborts BEFORE
# writing anything).
# ===========================================================================
set -uo pipefail
umask 077                      # artifacts are owner-only by default

# --- Configuration (from the environment; see backup.compose.yml) ----------
BACKUPS_DIR="${BACKUPS_DIR:-/backups}"
PROJECT_DIR="${PROJECT_DIR:-/project}"
AGE_KEY_FILE="${AGE_KEY_FILE:-/run/secrets/backup/age-identity.key}"
AGE_RECIPIENTS="${BACKUP_AGE_RECIPIENTS:-}"
RETAIN_DAILY="${BACKUP_RETENTION_DAILY:-7}"
RETAIN_WEEKLY="${BACKUP_RETENTION_WEEKLY:-4}"
EXTRA_TARGETS="${BACKUP_EXTRA_TARGETS:-}"
KUMA_URL="${BACKUP_UPTIME_KUMA_PUSH_URL:-}"
NC_TIMEOUT=5                   # seconds for the "is this engine up?" TCP probe

TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="${BACKUPS_DIR}/daily/${TS}"
STATUS_DIR="${BACKUPS_DIR}/status"
LOG_FILE="${STATUS_DIR}/backup.log"

# --- Loggers (also appended to the persistent log) -------------------------
log()  { printf '\033[0;32m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

# --- Counters --------------------------------------------------------------
ATTEMPTED=0
SUCCEEDED=0
FAILED=0
SKIPPED=0
declare -a MANIFEST=()         # "kind|label|file|status|bytes|sha256"
declare -a RECIP_ARGS=()       # age -r <recipient> ... built once below
RECIP_FP=""                    # age recipient(s) recorded in the manifest (a PUBLIC key)
# Manifest schema version. MUST stay in lock-step with BK_SUPPORTED_MANIFEST_SCHEMA
# in scripts/lib/backup-lib.sh (the dry-run planner + restore validation read it).
MANIFEST_SCHEMA=1

# Record one manifest line and update counters.
record() {
  local kind="$1" label="$2" file="$3" status="$4"
  local bytes="-" sum="-"
  if [[ "${status}" == "ok" && -f "${file}" ]]; then
    bytes="$(stat -c '%s' "${file}" 2>/dev/null || echo '-')"
    sum="$(sha256sum "${file}" 2>/dev/null | cut -d' ' -f1 || echo '-')"
  fi
  MANIFEST+=("${kind}|${label}|$(basename "${file}")|${status}|${bytes}|${sum}")
  case "${status}" in
    ok)      SUCCEEDED=$(( SUCCEEDED + 1 )) ;;
    failed)
      # A failed pipeline (e.g. the dump died mid-stream while age still wrote a
      # partial file) must NOT leave a half-written artifact that looks valid.
      rm -f "${file}" "${file}.partial" 2>/dev/null || true
      FAILED=$(( FAILED + 1 ))
      ;;
  esac
}

# --- Encrypt: read stdin, write an age-encrypted file atomically -----------
# Usage:  <producer> | enc /path/to/out.age
# Writes to out.age.partial then renames on success; removes the partial on any
# failure (so a broken pipe never leaves a half-written "valid-looking" backup).
enc() {
  local out="$1"
  if age "${RECIP_ARGS[@]}" -o "${out}.partial"; then
    mv -f "${out}.partial" "${out}"
    return 0
  fi
  rm -f "${out}.partial"
  return 1
}

# --- Is an engine actually listening? (the DB layer is on-demand) ----------
engine_up() { nc -z -w "${NC_TIMEOUT}" "$1" "$2" >/dev/null 2>&1; }

# --- Sanitize a label for use in a filename --------------------------------
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

# ===========================================================================
# 0. Validate encryption config — NEVER write a plaintext dump.
# ===========================================================================
mkdir -p "${STATUS_DIR}"
{
  echo "==============================================================="
  echo "pi-system backup run ${TS}"
} >>"${LOG_FILE}" 2>/dev/null || true

# Mirror all stdout/stderr into the persistent log from here on.
exec > >(tee -a "${LOG_FILE}") 2>&1

if [[ -n "${AGE_RECIPIENTS}" ]]; then
  # Explicit recipients (comma- or whitespace-separated). The Pi then needs only
  # the public key(s) to ENCRYPT; the identity is still required to restore.
  log "Encrypting to the recipient(s) from BACKUP_AGE_RECIPIENTS."
  # shellcheck disable=SC2206
  read -r -a _recips <<<"${AGE_RECIPIENTS//,/ }"
  for r in "${_recips[@]}"; do
    [[ -n "${r}" ]] && { RECIP_ARGS+=( -r "${r}" ); RECIP_FP+="${RECIP_FP:+,}${r}"; }
  done
elif [[ -s "${AGE_KEY_FILE}" ]]; then
  # Derive the public recipient from the mounted age identity.
  if recipient="$(age-keygen -y "${AGE_KEY_FILE}" 2>/dev/null)" && [[ -n "${recipient}" ]]; then
    log "Encrypting to the public key derived from the age identity."
    RECIP_ARGS+=( -r "${recipient}" )
    RECIP_FP="${recipient}"
  else
    err "Could not derive a recipient from the age identity at ${AGE_KEY_FILE}."
    err "The file may be missing, empty or not a valid age identity."
    exit 2
  fi
else
  err "No backup encryption configured: BACKUP_AGE_RECIPIENTS is empty and no"
  err "age identity is present at ${AGE_KEY_FILE}."
  err "Refusing to write plaintext backups. Generate a key with:"
  err "    ./scripts/backup.sh init-key"
  exit 2
fi

mkdir -p "${RUN_DIR}"
log "Writing encrypted backups to ${RUN_DIR}"

# ===========================================================================
# 1. PostgreSQL-family dumps (platform postgres + Keycloak DB + extra pg).
#    pg_dumpall captures roles + every database in the instance and restores
#    cleanly into a fresh server — the standard full-instance Postgres backup.
# ===========================================================================
backup_pg() {
  local label="$1" host="$2" port="$3" user="$4" password="$5"
  local file="${RUN_DIR}/pg.$(slug "${label}").sql.gz.age"
  if ! engine_up "${host}" "${port}"; then
    log "SKIP  pg/${label}: ${host}:${port} is not running."
    SKIPPED=$(( SKIPPED + 1 )); return 0
  fi
  ATTEMPTED=$(( ATTEMPTED + 1 ))
  log "DUMP  pg/${label} (${host}:${port}) ..."
  if PGPASSWORD="${password}" pg_dumpall -h "${host}" -p "${port}" -U "${user}" --no-password \
       | gzip -6 | enc "${file}"; then
    log "OK    pg/${label} -> $(basename "${file}")"
    record pg "${label}" "${file}" ok
  else
    err "FAIL  pg/${label}"
    record pg "${label}" "${file}" failed
  fi
}

# ===========================================================================
# 2. MySQL dump — the configured application database, with routines/triggers/
#    events, as a consistent snapshot (--single-transaction). Uses the official
#    MySQL client (caching_sha2_password over a non-TLS hop needs
#    --get-server-public-key). The password is passed via a temp defaults file
#    so it never appears in the process list.
# ===========================================================================
backup_mysql() {
  local label="$1" host="$2" port="$3" user="$4" password="$5" db="$6"
  local file="${RUN_DIR}/mysql.$(slug "${label}").sql.gz.age"
  if ! engine_up "${host}" "${port}"; then
    log "SKIP  mysql/${label}: ${host}:${port} is not running."
    SKIPPED=$(( SKIPPED + 1 )); return 0
  fi
  if [[ -z "${db}" ]]; then
    warn "SKIP  mysql/${label}: no database name configured (MYSQL_DATABASE empty)."
    SKIPPED=$(( SKIPPED + 1 )); return 0
  fi
  ATTEMPTED=$(( ATTEMPTED + 1 ))
  log "DUMP  mysql/${label} (db=${db}) ..."
  local cnf; cnf="$(mktemp)"
  printf '[client]\nhost=%s\nport=%s\nuser=%s\npassword=%s\nget-server-public-key\n' \
    "${host}" "${port}" "${user}" "${password}" >"${cnf}"
  if mysqldump --defaults-extra-file="${cnf}" \
        --single-transaction --routines --triggers --events --no-tablespaces \
        --databases "${db}" | gzip -6 | enc "${file}"; then
    log "OK    mysql/${label} -> $(basename "${file}")"
    record mysql "${label}" "${file}" ok
  else
    err "FAIL  mysql/${label}"
    record mysql "${label}" "${file}" failed
  fi
  rm -f "${cnf}"
}

# ===========================================================================
# 3. MongoDB dump — a single gzipped archive stream (mongodump --archive --gzip),
#    which mongorestore consumes directly. Dumps the configured DB if set, else
#    the whole instance.
# ===========================================================================
backup_mongo() {
  local label="$1" host="$2" port="$3" user="$4" password="$5" db="$6"
  local file="${RUN_DIR}/mongo.$(slug "${label}").archive.gz.age"
  if ! engine_up "${host}" "${port}"; then
    log "SKIP  mongo/${label}: ${host}:${port} is not running."
    SKIPPED=$(( SKIPPED + 1 )); return 0
  fi
  ATTEMPTED=$(( ATTEMPTED + 1 ))
  local dbarg=()
  [[ -n "${db}" ]] && dbarg=( --db "${db}" )
  log "DUMP  mongo/${label} (${db:-all databases}) ..."
  if mongodump --host "${host}" --port "${port}" \
        -u "${user}" -p "${password}" --authenticationDatabase admin \
        "${dbarg[@]}" --archive --gzip 2>/dev/null | enc "${file}"; then
    log "OK    mongo/${label} -> $(basename "${file}")"
    record mongo "${label}" "${file}" ok
  else
    err "FAIL  mongo/${label}"
    record mongo "${label}" "${file}" failed
  fi
}

# ===========================================================================
# 4. Redis RDB snapshot over the network (redis-cli --rdb). No volume access
#    needed — redis-cli asks the server for a fresh RDB and we encrypt it.
# ===========================================================================
backup_redis() {
  local label="redis" host="redis" port="6379" password="$1"
  local file="${RUN_DIR}/redis.dump.rdb.gz.age"
  if ! engine_up "${host}" "${port}"; then
    log "SKIP  redis: ${host}:${port} is not running."
    SKIPPED=$(( SKIPPED + 1 )); return 0
  fi
  ATTEMPTED=$(( ATTEMPTED + 1 ))
  log "DUMP  redis (${host}:${port}) ..."
  local tmp; tmp="$(mktemp)"
  if redis-cli -h "${host}" -p "${port}" -a "${password}" --no-auth-warning --rdb "${tmp}" >/dev/null 2>&1 \
       && gzip -6 -c "${tmp}" | enc "${file}"; then
    log "OK    redis -> $(basename "${file}")"
    record redis "${label}" "${file}" ok
  else
    err "FAIL  redis"
    record redis "${label}" "${file}" failed
  fi
  rm -f "${tmp}"
}

# ===========================================================================
# 5. Critical config — compose files, Caddyfile, .env, ... Encrypted like
#    everything else, so .env is NEVER stored in plaintext. data/ and secrets/
#    are excluded (the age key must NOT be backed up inside its own backup).
# ===========================================================================
backup_config() {
  local file="${RUN_DIR}/config.tar.gz.age"
  if [[ ! -d "${PROJECT_DIR}" ]]; then
    log "SKIP  config: ${PROJECT_DIR} not mounted."
    SKIPPED=$(( SKIPPED + 1 )); return 0
  fi
  ATTEMPTED=$(( ATTEMPTED + 1 ))
  log "DUMP  config (${PROJECT_DIR}) ..."
  if tar -C "${PROJECT_DIR}" \
        --exclude='./data' --exclude='./secrets' --exclude='./.git' \
        --exclude='*.bak' --exclude='*.bak.*' --exclude='*.bak-*' \
        -czf - . 2>/dev/null | enc "${file}"; then
    log "OK    config -> $(basename "${file}")"
    record config "config" "${file}" ok
  else
    err "FAIL  config"
    record config "config" "${file}" failed
  fi
}

# ===========================================================================
# 6. Extra targets — project-owned databases beyond the core engines, e.g.
#    content-admin's dedicated Postgres ("<project>-cms-db"). Whitespace-
#    separated list; each entry: engine:host:port:db:user:PASSWORD_ENV_VAR
#    The last field NAMES another variable in the environment that holds the
#    password (so the password itself never appears in the spec).
# ===========================================================================
backup_extra() {
  local spec="$1"
  local engine host port db user pwvar password
  IFS=':' read -r engine host port db user pwvar <<<"${spec}"
  if [[ -z "${engine}" || -z "${host}" || -z "${port}" || -z "${user}" || -z "${pwvar}" ]]; then
    warn "SKIP  extra target '${spec}': malformed (need engine:host:port:db:user:PASSWORD_ENV_VAR)."
    SKIPPED=$(( SKIPPED + 1 )); return 0
  fi
  password="${!pwvar:-}"
  if [[ -z "${password}" ]]; then
    warn "SKIP  extra target '${host}': password env var '${pwvar}' is empty/unset."
    SKIPPED=$(( SKIPPED + 1 )); return 0
  fi
  case "${engine}" in
    postgres|pg) backup_pg    "${host}" "${host}" "${port}" "${user}" "${password}" ;;
    mysql)       backup_mysql "${host}" "${host}" "${port}" "${user}" "${password}" "${db}" ;;
    mongo)       backup_mongo "${host}" "${host}" "${port}" "${user}" "${password}" "${db}" ;;
    *) warn "SKIP  extra target '${host}': unknown engine '${engine}'."; SKIPPED=$(( SKIPPED + 1 )) ;;
  esac
}

# ===========================================================================
# Run all backups.
# ===========================================================================
# Core platform engines (only those currently running are dumped).
backup_pg    "postgres"    "postgres"    "5432" "${POSTGRES_USER:-}"   "${POSTGRES_PASSWORD:-}"
backup_pg    "keycloak-db" "keycloak-db" "5432" "${KC_DB_USERNAME:-}"  "${KC_DB_PASSWORD:-}"
backup_mysql "mysql"       "mysql"       "3306" "root"                 "${MYSQL_ROOT_PASSWORD:-}" "${MYSQL_DATABASE:-}"
backup_mongo "mongo"       "mongo"       "27017" "${MONGO_INITDB_ROOT_USERNAME:-}" "${MONGO_INITDB_ROOT_PASSWORD:-}" "${MONGO_INITDB_DATABASE:-}"
backup_redis "${REDIS_PASSWORD:-}"

# Extra project databases.
if [[ -n "${EXTRA_TARGETS}" ]]; then
  for spec in ${EXTRA_TARGETS}; do
    backup_extra "${spec}"
  done
fi

# Critical config (always attempted).
backup_config

# ===========================================================================
# 7. Manifest for this run.
# ===========================================================================
# The manifest is the integrity record the dry-run planner + restore validation read:
# a per-member checksum + byte size, plus the schema version, the creation time, and
# the age recipient FINGERPRINT (a PUBLIC key — safe in plaintext) so a restore can be
# matched to the key that decrypts it. It is written plaintext alongside the .age files.
{
  echo "# pi-system backup manifest"
  echo "# schema: ${MANIFEST_SCHEMA}"
  echo "# run: ${TS}"
  echo "# created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "# age_recipient: ${RECIP_FP:--}"
  echo "# fields: kind|label|file|status|bytes|sha256"
  printf '%s\n' "${MANIFEST[@]}"
} >"${RUN_DIR}/manifest.txt"

# ===========================================================================
# 8. Weekly promotion (one run per ISO week) + retention pruning.
# ===========================================================================
OVERALL="ok"
(( FAILED > 0 )) && OVERALL="failed"

prune() {                      # keep the newest $2 subdirectories of $1
  local dir="$1" keep="$2" old
  [[ -d "${dir}" ]] || return 0
  ls -1dt "${dir}"/*/ 2>/dev/null | tail -n +"$(( keep + 1 ))" | while read -r old; do
    rm -rf "${old}" && log "PRUNE removed old backup $(basename "${old%/}")"
  done
}

if [[ "${OVERALL}" == "ok" ]]; then
  week="$(date +%G-%V)"        # ISO year-week, e.g. 2026-21
  if ! ls -1d "${BACKUPS_DIR}/weekly/${week}__"*/ >/dev/null 2>&1; then
    mkdir -p "${BACKUPS_DIR}/weekly"
    cp -a "${RUN_DIR}" "${BACKUPS_DIR}/weekly/${week}__${TS}"
    log "PROMOTE this run to weekly snapshot ${week}__${TS}"
  fi
fi
prune "${BACKUPS_DIR}/daily"  "${RETAIN_DAILY}"
prune "${BACKUPS_DIR}/weekly" "${RETAIN_WEEKLY}"

# ===========================================================================
# 9. Status file (machine-readable; Uptime Kuma / operators can watch it).
# ===========================================================================
FINISHED="$(date +%Y-%m-%dT%H:%M:%S%z)"
cat >"${STATUS_DIR}/last-backup.json" <<JSON
{
  "run": "${TS}",
  "finished_at": "${FINISHED}",
  "result": "${OVERALL}",
  "attempted": ${ATTEMPTED},
  "succeeded": ${SUCCEEDED},
  "failed": ${FAILED},
  "skipped": ${SKIPPED},
  "run_dir": "${RUN_DIR}"
}
JSON

# ===========================================================================
# 10. Summary + optional Uptime Kuma push + exit code.
# ===========================================================================
echo
log "Summary: ${SUCCEEDED} ok, ${FAILED} failed, ${SKIPPED} skipped (of ${ATTEMPTED} attempted)."
log "Result: ${OVERALL}. Run dir: ${RUN_DIR}"

if [[ -n "${KUMA_URL}" ]]; then
  if [[ "${OVERALL}" == "ok" ]]; then
    curl -fsS -m 10 "${KUMA_URL}?status=up&msg=$(slug "ok-${SUCCEEDED}ok-${SKIPPED}skip")&ping=" >/dev/null 2>&1 \
      && log "Pushed OK heartbeat to Uptime Kuma." || warn "Uptime Kuma push failed (non-fatal)."
  else
    curl -fsS -m 10 "${KUMA_URL}?status=down&msg=$(slug "backup-failed-${FAILED}")" >/dev/null 2>&1 || true
    warn "Pushed DOWN heartbeat to Uptime Kuma."
  fi
fi

if (( FAILED > 0 )); then
  err "Backup completed WITH FAILURES — see ${LOG_FILE}."
  exit 1
fi
log "Backup completed successfully."
exit 0
