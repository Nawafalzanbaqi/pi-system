#!/usr/bin/env bash
# ===========================================================================
# pi-system — REAL restore into LIVE databases (operator-confirmed only)
# ---------------------------------------------------------------------------
# ⚠  THIS OVERWRITES LIVE DATA.  ⚠
#
# This is the deliberately-guarded counterpart to the automated drill
# (scripts/backup-verify.sh, which only ever restores into throwaway
# instances). Use THIS script only during a real recovery, when you intend to
# overwrite the live databases with the contents of a backup.
#
# Safety design:
#   * It does NOTHING without the explicit --confirm flag.
#   * On a terminal it ALSO requires you to type the word RESTORE.
#   * Non-interactively it ALSO requires --yes (so it can never be triggered by
#     accident, and is NEVER run automatically / on a schedule).
#   * --dry-run shows exactly what would happen and changes nothing.
#
# It restores by connecting to the LIVE database BY SERVICE NAME on the internal
# network (the engine must be up), using the credentials in .env.
#
# Usage:
#     ./scripts/restore.sh --engine <target> [--run <dir>] [--artifact <file>]
#                          --confirm [--yes] [--dry-run]
#
#   --engine <target>   postgres | keycloak-db | mysql | mongo | redis | config
#   --run <dir>         Backup run to restore FROM (default: the latest).
#   --artifact <file>   Restore a specific artifact file instead of the one
#                       auto-selected for the engine.
#   --confirm           REQUIRED. Acknowledge that this overwrites live data.
#   --yes               Required IN ADDITION to --confirm when NOT on a terminal.
#   --dry-run           Print the plan and exit without changing anything.
#   -h, --help          Show this help and exit.
#
# RECOVERY PROCEDURE (read docs/README.md "Backup & restore" first):
#   1. Make sure you have the age identity that the backup was encrypted with.
#   2. Stop any application that writes to the target database.
#   3. For Postgres/Keycloak: ideally restore into a FRESH instance (drop &
#      recreate the database, or restore into an empty volume) so role/database
#      CREATE statements apply cleanly.
#   4. Run this script for the target engine.
#   5. Verify, then restart your applications.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[restore]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
BACKUP_COMPOSE="services/backup/backup.compose.yml"

VALID_ENGINES="postgres keycloak-db mysql mongo redis config"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/restore.sh --engine <target> --confirm [options]

  --engine <target>   postgres | keycloak-db | mysql | mongo | redis | config
  --run <dir>         Backup run to restore FROM (default: latest).
  --artifact <file>   Restore a specific artifact instead of the auto-selected one.
  --confirm           REQUIRED. Acknowledges this OVERWRITES LIVE DATA.
  --yes               Also required when NOT on a terminal.
  --dry-run           Print the plan and exit without changing anything.
  -h, --help          Show this help and exit.

⚠ This overwrites live data and never runs automatically. The automated,
non-destructive drill is ./scripts/backup-verify.sh. See docs/README.md.
EOF
}

# --- Read a value from .env WITHOUT sourcing it ----------------------------
env_get() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*${key}=" .env 2>/dev/null | tail -n1 || true)"
  val="${line#*=}"; val="${val%$'\r'}"
  val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  if [[ "${val}" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
  elif [[ "${val}" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"; fi
  printf '%s' "${val}"
}
resolve_path() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "${PROJECT_ROOT}" "${1#./}" ;; esac; }
contains() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- Parse arguments -------------------------------------------------------
ENGINE=""; RUN_OPT=""; ARTIFACT_OPT=""; CONFIRM=0; YES=0; DRYRUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --engine) ENGINE="${2:-}"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    --run) RUN_OPT="${2:-}"; shift 2 ;;
    --run=*) RUN_OPT="${1#*=}"; shift ;;
    --artifact) ARTIFACT_OPT="${2:-}"; shift 2 ;;
    --artifact=*) ARTIFACT_OPT="${1#*=}"; shift ;;
    --confirm) CONFIRM=1; shift ;;
    --yes) YES=1; shift ;;
    --dry-run) DRYRUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; usage; exit 1 ;;
  esac
done

[[ -n "${ENGINE}" ]] || { err "--engine is required."; usage; exit 1; }
contains "${ENGINE}" "${VALID_ENGINES}" || { err "Unknown engine: '${ENGINE}'. Valid: ${VALID_ENGINES}."; exit 1; }

# --- Preconditions ---------------------------------------------------------
[[ -f ".env" ]] || { err ".env not found. Run ./scripts/setup.sh first."; exit 1; }
for f in "${BASE_COMPOSE}" "${BACKUP_COMPOSE}"; do
  [[ -f "${f}" ]] || { err "Missing required file: ${f}"; exit 1; }
done
docker compose version >/dev/null 2>&1 || { err "Docker Compose v2 not available."; exit 1; }

PROJECT_NAME="$(env_get COMPOSE_PROJECT_NAME)"; PROJECT_NAME="${PROJECT_NAME:-pi-system}"
IMAGE="${PROJECT_NAME}/backup:1.0.0"
INTERNAL_NET="$(env_get INTERNAL_NETWORK_NAME)"; INTERNAL_NET="${INTERNAL_NET:-pi_internal}"
KEY_FILE_REL="$(env_get BACKUP_AGE_KEY_FILE)"; KEY_FILE_REL="${KEY_FILE_REL:-./secrets/backup/age-identity.key}"
KEY_FILE_ABS="$(resolve_path "${KEY_FILE_REL}")"
KEY_DIR="$(dirname "${KEY_FILE_ABS}")"; KEY_BN="$(basename "${KEY_FILE_ABS}")"
BACKUP_DIR_REL="$(env_get BACKUP_DIR)"; BACKUP_DIR_REL="${BACKUP_DIR_REL:-./data/backups}"
BACKUP_DIR_ABS="$(resolve_path "${BACKUP_DIR_REL}")"

[[ -s "${KEY_FILE_ABS}" ]] || { err "age identity not found at ${KEY_FILE_REL} — cannot decrypt. Restore it from your offline copy."; exit 1; }

# --- Pick the run directory ------------------------------------------------
RUN_DIR_ABS=""
if [[ -n "${RUN_OPT}" ]]; then
  RUN_DIR_ABS="$(resolve_path "${RUN_OPT}")"
else
  latest="$(ls -1dt "${BACKUP_DIR_ABS}/daily"/*/ 2>/dev/null | head -1 || true)"
  [[ -z "${latest}" ]] && latest="$(ls -1dt "${BACKUP_DIR_ABS}/weekly"/*/ 2>/dev/null | head -1 || true)"
  RUN_DIR_ABS="${latest%/}"
fi
[[ -n "${RUN_DIR_ABS}" && -d "${RUN_DIR_ABS}" ]] || { err "No backup run found (looked in ${BACKUP_DIR_REL})."; exit 1; }

# --- Select the artifact for the engine ------------------------------------
pick_artifact() {
  local pat="$1" m
  if [[ -n "${ARTIFACT_OPT}" ]]; then printf '%s' "${ARTIFACT_OPT}"; return 0; fi
  m="$(ls -1 "${RUN_DIR_ABS}"/${pat} 2>/dev/null | head -1 || true)"
  printf '%s' "${m}"
}
case "${ENGINE}" in
  postgres)    ARTIFACT="$(pick_artifact 'pg.postgres.sql.gz.age')" ;;
  keycloak-db) ARTIFACT="$(pick_artifact 'pg.keycloak-db.sql.gz.age')" ;;
  mysql)       ARTIFACT="$(pick_artifact 'mysql.*.sql.gz.age')" ;;
  mongo)       ARTIFACT="$(pick_artifact 'mongo.*.archive.gz.age')" ;;
  redis)       ARTIFACT="$(pick_artifact 'redis.dump.rdb.gz.age')" ;;
  config)      ARTIFACT="$(pick_artifact 'config.tar.gz.age')" ;;
esac
[[ -n "${ARTIFACT}" && -f "${ARTIFACT}" ]] || { err "No matching artifact for '${ENGINE}' in ${RUN_DIR_ABS}."; exit 1; }
ART="$(basename "${ARTIFACT}")"

# --- The plan + confirmation gate ------------------------------------------
echo
warn "============================================================"
warn " REAL RESTORE — THIS OVERWRITES LIVE DATA"
warn "============================================================"
warn " engine    : ${ENGINE}"
warn " from      : ${RUN_DIR_ABS#${PROJECT_ROOT}/}/${ART}"
warn " target    : the LIVE '${ENGINE}' on network '${INTERNAL_NET}'"
warn "============================================================"

if [[ "${DRYRUN}" -eq 1 ]]; then
  log "[dry-run] No changes made. Re-run with --confirm to perform the restore."
  exit 0
fi
if [[ "${CONFIRM}" -ne 1 ]]; then
  err "Refusing to proceed without --confirm (this overwrites live data)."
  err "Add --confirm (and on a terminal you will also be asked to type RESTORE)."
  exit 1
fi
if [[ -t 0 && -t 1 ]]; then
  printf '%s' 'Type RESTORE (all caps) to proceed: '
  read -r ANS
  [[ "${ANS}" == "RESTORE" ]] || { err "Confirmation phrase not matched. Aborting."; exit 1; }
else
  [[ "${YES}" -eq 1 ]] || { err "Non-interactive run: also pass --yes to proceed."; exit 1; }
fi

# Ensure the toolbox image exists.
log "Ensuring the backup toolbox image is built ..."
docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${BACKUP_COMPOSE}" --profile backup build backup >/dev/null

# Run the toolbox on the LIVE internal network, with .env (creds) + key + run dir.
# $1 = inner bash command. ${KEY_BN}/${ART} are expanded HERE; \$DB_VARS are left
# for the container to expand from --env-file (so secrets never hit the host CLI).
restore_run() {
  docker run --rm --network "${INTERNAL_NET}" --env-file .env \
    -v "${KEY_DIR}:/key:ro" -v "${RUN_DIR_ABS}:/bk:ro" \
    --entrypoint bash "${IMAGE}" -c "$1"
}

case "${ENGINE}" in
  postgres)
    warn "Restoring the FULL Postgres cluster dump into live 'postgres'."
    warn "For a clean result the target should be empty (drop & recreate first)."
    restore_run "age -d -i /key/${KEY_BN} /bk/${ART} | gunzip | PGPASSWORD=\"\$POSTGRES_PASSWORD\" psql -h postgres -U \"\$POSTGRES_USER\" -d postgres -v ON_ERROR_STOP=0"
    log "Postgres restore finished (review the output above for any errors)."
    ;;
  keycloak-db)
    warn "Restoring into the live isolated Keycloak DB ('keycloak-db')."
    restore_run "age -d -i /key/${KEY_BN} /bk/${ART} | gunzip | PGPASSWORD=\"\$KC_DB_PASSWORD\" psql -h keycloak-db -U \"\$KC_DB_USERNAME\" -d postgres -v ON_ERROR_STOP=0"
    log "Keycloak DB restore finished."
    ;;
  mysql)
    warn "Restoring into live 'mysql' (existing tables in the dumped DB are replaced)."
    restore_run "age -d -i /key/${KEY_BN} /bk/${ART} | gunzip | mysql --host=mysql --port=3306 --user=root --password=\"\$MYSQL_ROOT_PASSWORD\" --get-server-public-key"
    log "MySQL restore finished."
    ;;
  mongo)
    warn "Restoring into live 'mongo' (--drop replaces the restored collections)."
    restore_run "age -d -i /key/${KEY_BN} /bk/${ART} | mongorestore --host mongo:27017 -u \"\$MONGO_INITDB_ROOT_USERNAME\" -p \"\$MONGO_INITDB_ROOT_PASSWORD\" --authenticationDatabase admin --archive --gzip --drop"
    log "MongoDB restore finished."
    ;;
  redis)
    # A live RDB restore must replace the on-disk snapshot and restart the
    # server (and the platform runs Redis with AOF on, which takes precedence).
    # Doing that behind the operator's back is risky, so we decrypt the RDB for
    # you and print the exact, safe manual steps instead of guessing.
    OUT="${BACKUP_DIR_ABS}/restore-staging"
    mkdir -p "${OUT}"; chmod 700 "${OUT}" 2>/dev/null || true
    # Decrypt the RDB to a staging dir via an explicit writable mount (no live DB
    # is touched here — the offline steps below are what actually restore Redis).
    docker run --rm \
      -v "${KEY_DIR}:/key:ro" -v "${RUN_DIR_ABS}:/bk:ro" -v "${OUT}:/out" \
      --entrypoint bash "${IMAGE}" -c "age -d -i /key/${KEY_BN} /bk/${ART} | gunzip > /out/dump.rdb"
    warn "Redis must be restored OFFLINE. Decrypted snapshot written to:"
    warn "    ${OUT}/dump.rdb"
    cat >&2 <<EOF
Manual Redis recovery steps (Redis runs with AOF enabled):
  1. Stop Redis:           ./scripts/db.sh redis down
  2. Replace its data:     load ${OUT}/dump.rdb into the redis_data volume as
                           /data/dump.rdb AND remove the AOF files under
                           /data/appendonlydir (so the RDB is used on next start),
                           e.g.:
       docker run --rm -v ${PROJECT_NAME}_redis_data:/data -v "${OUT}":/in alpine:3.21 \\
         sh -c 'rm -rf /data/appendonlydir /data/dump.rdb && cp /in/dump.rdb /data/dump.rdb'
  3. Start Redis:          ./scripts/db.sh redis up
  4. Verify:               docker exec ${PROJECT_NAME}_redis redis-cli DBSIZE
EOF
    log "Redis snapshot staged; complete the offline steps above."
    ;;
  config)
    OUT="${BACKUP_DIR_ABS}/restore-staging/config-${ART%.tar.gz.age}"
    mkdir -p "${OUT}"; chmod 700 "$(dirname "${OUT}")" 2>/dev/null || true
    docker run --rm \
      -v "${KEY_DIR}:/key:ro" -v "${RUN_DIR_ABS}:/bk:ro" -v "${OUT}:/out" \
      --entrypoint bash "${IMAGE}" -c "age -d -i /key/${KEY_BN} /bk/${ART} | tar -xzf - -C /out"
    warn "Config archive extracted to (NOT applied automatically):"
    warn "    ${OUT}"
    log  "Review the files and copy back only what you need (e.g. .env, compose files)."
    ;;
esac

echo
log "Restore action for '${ENGINE}' complete. Verify the data, then restart your apps."
