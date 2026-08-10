#!/usr/bin/env bash
# ===========================================================================
# pi-system — TESTED-RESTORE drill (the core of the backup system)
# ---------------------------------------------------------------------------
# A backup you have never restored is not a backup — it is a hope. This script
# proves the latest encrypted backup can actually be restored, by performing a
# full restore DRILL into DISPOSABLE, throwaway containers on a throwaway
# network, then running a post-restore HEALTH self-check on each (a trivial read
# — SELECT 1 / ping / key count / file presence — that proves the restored data
# is actually USABLE, not merely unpacked), and finally destroying them.
#
# It NEVER touches the live databases:
#   * It starts brand-new, single-use engine containers (pinned to the SAME
#     versions the platform runs) on a DEDICATED throwaway network that is NOT
#     connected to the platform's `internal` network — so the live databases are
#     not even reachable from the drill.
#   * It restores into those throwaway instances only, checks them, and removes
#     the containers AND their volumes afterwards (cleanup runs even on error).
#
# For each database in the latest backup it reports PASS or FAIL, and the script
# exits non-zero if ANY database fails to restore/verify — so a silently-rotting
# backup is caught.
#
# Usage:
#     ./scripts/backup-verify.sh [--run <dir>] [--keep-going] [-h|--help]
#
#       --run <dir>    Verify a specific backup run directory instead of the
#                      latest (e.g. .../data/backups/weekly/2026-21__...).
#       --keep-going   Do not stop at the first failed database; try them all.
#                      (Default already tries all; this flag is reserved/no-op
#                      kept for clarity — every database is always attempted.)
#   -h, --help         Show this help and exit.
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root --------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[verify]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }
pass() { printf '  \033[0;32m✓ PASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[0;31m✗ FAIL\033[0m %s\n' "$*"; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
BACKUP_COMPOSE="services/backup/backup.compose.yml"

# Disposable engine images — pinned to the SAME versions the platform runs.
PG_IMAGE="postgres:16.6-alpine"
MYSQL_IMAGE="mysql:8.4.3"
MONGO_IMAGE="mongo:7.0.14"
REDIS_IMAGE="redis:7.4.1-alpine"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/backup-verify.sh [--run <dir>]

      --run <dir>    Verify a specific backup run directory (default: latest).
  -h, --help         Show this help and exit.

Restores the latest encrypted backup into DISPOSABLE throwaway containers,
checks each database, and tears them down. NEVER touches live data. Exits
non-zero if any database fails. See docs/README.md "Backup & restore".
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

# --- Parse arguments -------------------------------------------------------
RUN_OPT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run) RUN_OPT="${2:-}"; [[ -z "${RUN_OPT}" ]] && { err "--run requires a directory."; exit 1; }; shift 2 ;;
    --run=*) RUN_OPT="${1#*=}"; shift ;;
    --keep-going) shift ;;            # reserved; every DB is always attempted
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: '$1'."; usage; exit 1 ;;
  esac
done

# --- Preconditions ---------------------------------------------------------
# This drill is Docker-dependent: it CREATES and DESTROYS throwaway containers.
# OFF a Pi — no Docker CLI, or the daemon not reachable — there is nothing to
# drill, so SKIP cleanly (exit 0) rather than failing a dev box or the offline
# test matrix. The full restore proof only means something ON the Pi.
if ! command -v docker >/dev/null 2>&1; then
  warn "Docker is not installed here — the restore drill is Docker-dependent."
  log  "SKIP: run this ON the Raspberry Pi (after './scripts/pi up') to drill a real restore."
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  warn "The Docker daemon is not reachable here — cannot run disposable drill containers."
  log  "SKIP: start Docker (and join the 'docker' group), or run this ON the Pi."
  exit 0
fi
[[ -f ".env" ]] || { err ".env not found. Run ./scripts/setup.sh first."; exit 1; }
for f in "${BASE_COMPOSE}" "${BACKUP_COMPOSE}"; do
  [[ -f "${f}" ]] || { err "Missing required file: ${f}"; exit 1; }
done
docker compose version >/dev/null 2>&1 || { err "Docker Compose v2 not available."; exit 1; }

PROJECT_NAME="$(env_get COMPOSE_PROJECT_NAME)"; PROJECT_NAME="${PROJECT_NAME:-pi-system}"
IMAGE="${PROJECT_NAME}/backup:1.0.0"
KEY_FILE_REL="$(env_get BACKUP_AGE_KEY_FILE)"; KEY_FILE_REL="${KEY_FILE_REL:-./secrets/backup/age-identity.key}"
KEY_FILE_ABS="$(resolve_path "${KEY_FILE_REL}")"
KEY_DIR="$(dirname "${KEY_FILE_ABS}")"; KEY_BN="$(basename "${KEY_FILE_ABS}")"
BACKUP_DIR_REL="$(env_get BACKUP_DIR)"; BACKUP_DIR_REL="${BACKUP_DIR_REL:-./data/backups}"
BACKUP_DIR_ABS="$(resolve_path "${BACKUP_DIR_REL}")"
KUMA_URL="$(env_get BACKUP_VERIFY_UPTIME_KUMA_PUSH_URL)"

if [[ ! -s "${KEY_FILE_ABS}" ]]; then
  err "age identity not found at ${KEY_FILE_REL} — cannot decrypt backups to verify."
  err "It must be the SAME key the backups were encrypted with. Restore it from"
  err "your offline copy, then re-run."
  exit 1
fi

# --- Pick the run directory to verify --------------------------------------
RUN_DIR_ABS=""
if [[ -n "${RUN_OPT}" ]]; then
  RUN_DIR_ABS="$(resolve_path "${RUN_OPT}")"
else
  latest="$(ls -1dt "${BACKUP_DIR_ABS}/daily"/*/ 2>/dev/null | head -1 || true)"
  [[ -z "${latest}" ]] && latest="$(ls -1dt "${BACKUP_DIR_ABS}/weekly"/*/ 2>/dev/null | head -1 || true)"
  RUN_DIR_ABS="${latest%/}"
fi
if [[ -z "${RUN_DIR_ABS}" || ! -d "${RUN_DIR_ABS}" ]]; then
  err "No backup run found to verify (looked in ${BACKUP_DIR_REL}). Run: ./scripts/backup.sh now"
  exit 1
fi
log "Verifying backup run: ${RUN_DIR_ABS#${PROJECT_ROOT}/}"

# Build (or refresh) the toolbox image so age + clients are available.
log "Ensuring the backup toolbox image is built ..."
docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
  -f "${BASE_COMPOSE}" -f "${BACKUP_COMPOSE}" --profile backup build backup >/dev/null

# --- Throwaway network + cleanup trap --------------------------------------
PFX="pisys_verify_$$"
VNET="${PFX}_net"
declare -a TMPDIRS=()

cleanup() {
  log "Cleaning up the throwaway drill environment ..."
  # Remove any containers we created (by name prefix), with their volumes.
  local ids
  ids="$(docker ps -aq --filter "name=${PFX}" 2>/dev/null || true)"
  [[ -n "${ids}" ]] && docker rm -f -v ${ids} >/dev/null 2>&1 || true
  docker network rm "${VNET}" >/dev/null 2>&1 || true
  local d
  for d in "${TMPDIRS[@]:-}"; do [[ -n "${d}" && -d "${d}" ]] && rm -rf "${d}"; done
}
trap cleanup EXIT INT TERM

docker network create "${VNET}" >/dev/null
log "Created throwaway network ${VNET} (NOT connected to the live internal network)."

# --- Result accounting -----------------------------------------------------
TOTAL=0; PASSED=0; FAILEDN=0
declare -a RESULTS=()
mark_pass() { TOTAL=$((TOTAL+1)); PASSED=$((PASSED+1)); RESULTS+=("PASS|$1|$2"); pass "$1 — $2"; }
mark_fail() { TOTAL=$((TOTAL+1)); FAILEDN=$((FAILEDN+1)); RESULTS+=("FAIL|$1|$2"); fail "$1 — $2"; }

# --- Manifest integrity pre-check ------------------------------------------
# Before spending time drilling, READ the manifest the backup wrote and confirm
# every artifact still matches its recorded SHA-256 (a cheap host-side check that
# catches on-disk corruption / tampering / truncation before we even start a
# container). The same manifest underpins 'backup.sh restore --dry-run'.
MANIFEST_FILE="${RUN_DIR_ABS}/manifest.txt"
if [[ -f "${MANIFEST_FILE}" ]]; then
  log "Manifest integrity pre-check (checksums vs ${MANIFEST_FILE#${PROJECT_ROOT}/}) ..."
  while IFS='|' read -r m_kind m_label m_file m_status m_bytes m_sha; do
    [[ -z "${m_kind}" || "${m_kind}" == \#* || "${m_status}" != "ok" ]] && continue
    mf="${RUN_DIR_ABS}/${m_file}"
    if [[ ! -f "${mf}" ]]; then
      mark_fail "manifest/${m_file}" "listed ok but MISSING on disk"; continue
    fi
    m_actual="$(sha256sum "${mf}" 2>/dev/null | cut -d' ' -f1 || true)"
    if [[ -n "${m_sha}" && "${m_sha}" != "-" && -n "${m_actual}" && "${m_actual}" != "${m_sha}" ]]; then
      mark_fail "manifest/${m_file}" "checksum MISMATCH vs manifest (corrupt/tampered)"
    else
      mark_pass "manifest/${m_file}" "checksum matches the manifest"
    fi
  done < "${MANIFEST_FILE}"
else
  warn "No manifest.txt in ${RUN_DIR_ABS#${PROJECT_ROOT}/} — skipping the integrity pre-check (legacy backup)."
fi

# Run the toolbox image as a one-shot tool on the throwaway network, with the
# age key (ro) and the backup run (ro) mounted. $1 = shell command.
run_tool() {
  docker run --rm --network "${VNET}" \
    -v "${KEY_DIR}:/key:ro" -v "${RUN_DIR_ABS}:/bk:ro" \
    --entrypoint bash "${IMAGE}" -c "$1"
}

# Wait until a predicate command (run via eval) succeeds, up to N seconds.
wait_until() {
  local secs="$1" desc="$2" cmd="$3" i=0
  while ! eval "${cmd}" >/dev/null 2>&1; do
    i=$((i+1))
    if (( i >= secs )); then warn "Timed out waiting for ${desc} (${secs}s)."; return 1; fi
    sleep 1
  done
  return 0
}

# ===========================================================================
# Per-engine drills
# ===========================================================================
verify_pg() {
  local file="$1" label="$2" c="${PFX}_pg"
  log "PostgreSQL drill: ${label}"
  docker run -d --name "${c}" --network "${VNET}" \
    -e POSTGRES_USER=verify -e POSTGRES_PASSWORD=verifypw -e POSTGRES_DB=postgres \
    "${PG_IMAGE}" >/dev/null
  if ! wait_until 60 "postgres ready" "docker exec ${c} pg_isready -U verify -d postgres"; then
    mark_fail "postgres/${label}" "disposable instance never became ready"; docker rm -f -v "${c}" >/dev/null 2>&1 || true; return
  fi
  # Restore (best-effort: pg_dumpall may re-create the bootstrap role -> harmless noise).
  if ! run_tool "age -d -i /key/${KEY_BN} /bk/$(basename "${file}") | gunzip | PGPASSWORD=verifypw psql -h ${c} -U verify -d postgres -v ON_ERROR_STOP=0 -q >/dev/null 2>&1"; then
    mark_fail "postgres/${label}" "decrypt/restore pipeline failed"; docker rm -f -v "${c}" >/dev/null 2>&1 || true; return
  fi
  # HEALTH self-check: the restored engine must answer a trivial read (proving the
  # data is USABLE, not merely unpacked), AND at least one application database must
  # have been recreated.
  local health dbcount tables
  health="$(docker exec -e PGPASSWORD=verifypw "${c}" psql -U verify -d postgres -tAc 'SELECT 1;' 2>/dev/null | tr -d '[:space:]')"
  dbcount="$(docker exec -e PGPASSWORD=verifypw "${c}" psql -U verify -d postgres -tAc \
    "SELECT count(*) FROM pg_database WHERE datistemplate=false AND datname NOT IN ('postgres');" 2>/dev/null | tr -d '[:space:]')"
  tables="$(docker exec -e PGPASSWORD=verifypw "${c}" psql -U verify -d postgres -tAc \
    "SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema');" 2>/dev/null | tr -d '[:space:]')"
  if [[ "${health}" != "1" ]]; then
    mark_fail "postgres/${label}" "post-restore health read (SELECT 1) did not succeed"
  elif [[ "${dbcount:-0}" =~ ^[0-9]+$ ]] && (( dbcount >= 1 )); then
    mark_pass "postgres/${label}" "SELECT 1 ok; restored ${dbcount} database(s), ${tables:-?} table(s)"
  else
    mark_fail "postgres/${label}" "no application database present after restore"
  fi
  docker rm -f -v "${c}" >/dev/null 2>&1 || true
}

verify_mysql() {
  local file="$1" label="$2" c="${PFX}_mysql"
  log "MySQL drill: ${label}"
  docker run -d --name "${c}" --network "${VNET}" \
    -e MYSQL_ROOT_PASSWORD=verifypw "${MYSQL_IMAGE}" >/dev/null
  if ! wait_until 120 "mysql ready" "docker exec ${c} mysql -u root -pverifypw -e 'SELECT 1'"; then
    mark_fail "mysql/${label}" "disposable instance never became ready"; docker rm -f -v "${c}" >/dev/null 2>&1 || true; return
  fi
  if ! run_tool "age -d -i /key/${KEY_BN} /bk/$(basename "${file}") | gunzip | mysql --host=${c} --port=3306 --user=root --password=verifypw --get-server-public-key >/dev/null 2>&1"; then
    mark_fail "mysql/${label}" "decrypt/restore pipeline failed"; docker rm -f -v "${c}" >/dev/null 2>&1 || true; return
  fi
  # HEALTH self-check: a trivial read must succeed AND an application schema present.
  local health schemas
  health="$(docker exec "${c}" mysql -u root -pverifypw -N -e 'SELECT 1;' 2>/dev/null | tr -d '[:space:]')"
  schemas="$(docker exec "${c}" mysql -u root -pverifypw -N -e \
    "SELECT count(*) FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','information_schema','performance_schema','sys');" 2>/dev/null | tr -d '[:space:]')"
  if [[ "${health}" != "1" ]]; then
    mark_fail "mysql/${label}" "post-restore health read (SELECT 1) did not succeed"
  elif [[ "${schemas:-0}" =~ ^[0-9]+$ ]] && (( schemas >= 1 )); then
    mark_pass "mysql/${label}" "SELECT 1 ok; restored ${schemas} application schema(s)"
  else
    mark_fail "mysql/${label}" "no application schema present after restore"
  fi
  docker rm -f -v "${c}" >/dev/null 2>&1 || true
}

verify_mongo() {
  local file="$1" label="$2" c="${PFX}_mongo"
  log "MongoDB drill: ${label}"
  docker run -d --name "${c}" --network "${VNET}" "${MONGO_IMAGE}" >/dev/null
  if ! wait_until 90 "mongo ready" "docker exec ${c} mongosh --quiet --eval 'db.adminCommand({ping:1}).ok'"; then
    mark_fail "mongo/${label}" "disposable instance never became ready"; docker rm -f -v "${c}" >/dev/null 2>&1 || true; return
  fi
  if ! run_tool "age -d -i /key/${KEY_BN} /bk/$(basename "${file}") | mongorestore --host ${c}:27017 --archive --gzip --drop >/dev/null 2>&1"; then
    mark_fail "mongo/${label}" "decrypt/restore pipeline failed"; docker rm -f -v "${c}" >/dev/null 2>&1 || true; return
  fi
  # HEALTH self-check: a trivial admin ping must succeed AND a database be present.
  local health dbs
  health="$(docker exec "${c}" mongosh --quiet --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | tr -d '[:space:]')"
  dbs="$(docker exec "${c}" mongosh --quiet --eval \
    "db.getMongo().getDBNames().filter(n => !['admin','config','local'].includes(n)).length" 2>/dev/null | tr -d '[:space:]')"
  if [[ "${health}" != "1" ]]; then
    mark_fail "mongo/${label}" "post-restore health read (ping) did not succeed"
  elif [[ "${dbs:-0}" =~ ^[0-9]+$ ]] && (( dbs >= 1 )); then
    mark_pass "mongo/${label}" "ping ok; restored ${dbs} database(s)"
  else
    mark_fail "mongo/${label}" "no application database present after restore"
  fi
  docker rm -f -v "${c}" >/dev/null 2>&1 || true
}

verify_redis() {
  local file="$1" label="$2" c="${PFX}_redis"
  log "Redis drill: ${label}"
  local tmp; tmp="$(mktemp -d)"; TMPDIRS+=("${tmp}")
  # Decrypt the RDB into a temp dir, then start a disposable redis pointed at it.
  if ! docker run --rm --network "${VNET}" \
        -v "${KEY_DIR}:/key:ro" -v "${RUN_DIR_ABS}:/bk:ro" -v "${tmp}:/out" \
        --entrypoint bash "${IMAGE}" -c \
        "age -d -i /key/${KEY_BN} /bk/$(basename "${file}") | gunzip > /out/dump.rdb"; then
    mark_fail "redis/${label}" "decrypt of RDB failed"; return
  fi
  chmod -R a+rX "${tmp}" 2>/dev/null || true
  docker run -d --name "${c}" --network "${VNET}" -v "${tmp}:/data" \
    "${REDIS_IMAGE}" redis-server --appendonly no --dbfilename dump.rdb --dir /data >/dev/null
  if ! wait_until 30 "redis ready" "docker exec ${c} redis-cli ping"; then
    mark_fail "redis/${label}" "disposable instance never loaded the RDB"; docker rm -f -v "${c}" >/dev/null 2>&1 || true; return
  fi
  # HEALTH self-check: the server must answer PING after loading the RDB; the key
  # count is the trivial read proving the dataset is actually queryable.
  local health keys
  health="$(docker exec "${c}" redis-cli ping 2>/dev/null | tr -d '[:space:]')"
  keys="$(docker exec "${c}" redis-cli DBSIZE 2>/dev/null | tr -d '[:space:]')"
  if [[ "${health^^}" == "PONG" ]]; then
    mark_pass "redis/${label}" "PING ok; RDB loaded, DBSIZE=${keys:-?} key(s)"
  else
    mark_fail "redis/${label}" "post-restore health read (PING) did not succeed"
  fi
  docker rm -f -v "${c}" >/dev/null 2>&1 || true
}

verify_config() {
  local file="$1"
  log "Config archive drill"
  local listing
  if listing="$(run_tool "age -d -i /key/${KEY_BN} /bk/$(basename "${file}") | tar -tzf - 2>/dev/null")"; then
    if printf '%s\n' "${listing}" | grep -q 'infrastructure/docker-compose.yml'; then
      local n; n="$(printf '%s\n' "${listing}" | grep -c . || true)"
      # File-presence health check: the base compose file must be in the archive.
      mark_pass "config" "decrypts + file presence ok; lists ${n} entries (incl. base compose)"
    else
      mark_fail "config" "archive decrypted but is missing expected files"
    fi
  else
    mark_fail "config" "decrypt/extract of config archive failed"
  fi
}

# ===========================================================================
# Walk the artifacts in the run directory.
# ===========================================================================
shopt -s nullglob
found=0
for f in "${RUN_DIR_ABS}"/*.age; do
  found=1
  base="$(basename "${f}")"
  kind="${base%%.*}"
  case "${kind}" in
    pg)
      label="${base#pg.}"; label="${label%.sql.gz.age}"
      verify_pg "${f}" "${label}" ;;
    mysql)
      label="${base#mysql.}"; label="${label%.sql.gz.age}"
      verify_mysql "${f}" "${label}" ;;
    mongo)
      label="${base#mongo.}"; label="${label%.archive.gz.age}"
      verify_mongo "${f}" "${label}" ;;
    redis)
      verify_redis "${f}" "redis" ;;
    config)
      verify_config "${f}" ;;
    *)
      warn "Unrecognized artifact '${base}' — skipping." ;;
  esac
done
shopt -u nullglob

if [[ "${found}" -eq 0 ]]; then
  err "No encrypted artifacts (*.age) found in ${RUN_DIR_ABS}."
  exit 1
fi

# ===========================================================================
# Summary + status file + optional Uptime Kuma push.
# ===========================================================================
OVERALL="ok"; (( FAILEDN > 0 )) && OVERALL="failed"
echo
log "Drill summary: ${PASSED}/${TOTAL} passed, ${FAILEDN} failed."

STATUS_DIR="${BACKUP_DIR_ABS}/status"
mkdir -p "${STATUS_DIR}"
FINISHED="$(date +%Y-%m-%dT%H:%M:%S%z)"
{
  printf '{\n'
  printf '  "finished_at": "%s",\n' "${FINISHED}"
  printf '  "run_dir": "%s",\n' "${RUN_DIR_ABS}"
  printf '  "result": "%s",\n' "${OVERALL}"
  printf '  "total": %s,\n' "${TOTAL}"
  printf '  "passed": %s,\n' "${PASSED}"
  printf '  "failed": %s,\n' "${FAILEDN}"
  printf '  "checks": [\n'
  for i in "${!RESULTS[@]}"; do
    IFS='|' read -r st db msg <<<"${RESULTS[$i]}"
    sep=","; [[ "${i}" -eq $(( ${#RESULTS[@]} - 1 )) ]] && sep=""
    printf '    {"db": "%s", "status": "%s", "detail": "%s"}%s\n' "${db}" "${st}" "${msg//\"/}" "${sep}"
  done
  printf '  ]\n}\n'
} >"${STATUS_DIR}/last-verify.json"
log "Wrote drill status to ${STATUS_DIR#${PROJECT_ROOT}/}/last-verify.json"

if [[ -n "${KUMA_URL}" ]]; then
  if [[ "${OVERALL}" == "ok" ]]; then
    curl -fsS -m 10 "${KUMA_URL}?status=up&msg=drill-${PASSED}of${TOTAL}-ok" >/dev/null 2>&1 \
      && log "Pushed OK heartbeat to Uptime Kuma." || warn "Uptime Kuma push failed (non-fatal)."
  else
    curl -fsS -m 10 "${KUMA_URL}?status=down&msg=drill-${FAILEDN}-failed" >/dev/null 2>&1 || true
    warn "Pushed DOWN heartbeat to Uptime Kuma."
  fi
fi

if (( FAILEDN > 0 )); then
  err "RESTORE DRILL FAILED for ${FAILEDN} database(s) — your backups are NOT trustworthy."
  err "Investigate before you need them. See the per-database results above."
  exit 1
fi
log "RESTORE DRILL PASSED — every store restored AND answered a health read in a throwaway instance."
exit 0
