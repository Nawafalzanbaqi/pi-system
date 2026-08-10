# shellcheck shell=bash
# ===========================================================================
# pi-system — preflight check LIBRARY (pure logic + mockable seams)
# ---------------------------------------------------------------------------
# This file is SOURCED by scripts/preflight.sh and by the test harness in
# tests/preflight/. It defines:
#
#   1. PURE functions  — classifiers and parsers that take their inputs as
#      arguments (or read a given file / stdin) and emit a verdict
#      (PASS/WARN/FAIL/...) or a result, with NO dependency on the live host.
#      These are what the tests exercise against fixtures, so preflight's
#      decision logic can be verified WITHOUT a real Docker/Pi.
#
#   2. SEAM functions  — thin wrappers around every external/system call
#      (docker, uname, df, /proc, findmnt, the registry). The orchestrator
#      calls ONLY these for system access; a test can redefine any of them to
#      inject a fixed value, so the same logic runs offline and on the Pi.
#
#   3. The component REGISTRY — data mapping each thing-you-can-run to its
#      compose file(s), Compose profile, and required .env variables.
#
# DESIGN RULES (so it stays testable and safe):
#   * READ-ONLY: nothing here starts/stops a container, writes a secret, or
#     mutates state. The only docker verbs used are read-only (version, config,
#     ps, network/volume ls, manifest inspect).
#   * NO `set -e` here — this is a library; the entrypoint owns shell options.
#   * Classifier functions print their verdict to stdout and `return 0`, so the
#     caller's `set -e` is never tripped by a verdict that happens to be FAIL.
#   * Predicate functions (pf_*_ok / pf_env_has / pf_manifest_arm64) return
#     0/1 and are only ever used inside `if`.
#   * Secret STRENGTH is NOT re-implemented here — preflight calls the existing
#     scripts/check-secrets.sh for that. This file only checks the PRESENCE of
#     required variables (a config-completeness concern, distinct from strength).
# ===========================================================================

# Guard against double-sourcing (the entrypoint and tests may both source it).
if [[ -n "${PF_LIB_SOURCED:-}" ]]; then return 0 2>/dev/null || true; fi
PF_LIB_SOURCED=1

# ---------------------------------------------------------------------------
# Verdict vocabulary. Higher number = worse. Used to fold many sub-results
# into one section verdict (the worst wins).
# ---------------------------------------------------------------------------
readonly PF_PASS="PASS"
readonly PF_WARN="WARN"
readonly PF_FAIL="FAIL"

# Fold two verdicts, returning the worse of the two (FAIL > WARN > PASS).
pf_worst() {
  local a="$1" b="$2"
  case "${a}|${b}" in
    *FAIL*) echo "FAIL" ;;
    *WARN*) echo "WARN" ;;
    *)      echo "PASS" ;;
  esac
}

# ===========================================================================
# SECTION 1 — PURE classifiers / parsers (the heart of the test surface)
# ===========================================================================

# --- .env reading WITHOUT executing the file -------------------------------
# Never `source` an .env (it could run arbitrary code and would mask quoting
# bugs). Mirrors the value-extraction approach in scripts/check-secrets.sh:
# take the LAST assignment of KEY, strip a trailing CR (CRLF files), trim edge
# whitespace, and remove ONE pair of surrounding quotes. The value is used only
# to test presence/length here — preflight never prints it.
pf_env_value() {
  local key="$1" file="$2" line val
  [[ -f "${file}" ]] || { printf ''; return 0; }
  line="$(grep -E "^[[:space:]]*${key}=" "${file}" | tail -n1 || true)"
  if [[ -z "${line}" ]]; then printf ''; return 0; fi
  val="${line#*=}"
  val="${val%$'\r'}"                      # strip trailing CR from CRLF files
  val="${val#"${val%%[![:space:]]*}"}"    # ltrim
  val="${val%"${val##*[![:space:]]}"}"    # rtrim
  if [[ "${val}" == \"*\" && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "${val}" == \'*\' && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "${val}"
}

# Does an assignment line for KEY exist at all (even if empty)?
pf_env_has() {
  local key="$1" file="$2"
  [[ -f "${file}" ]] && grep -qE "^[[:space:]]*${key}=" "${file}"
}

# Echo (one per line) the variables in "$@" that are MISSING from FILE or set
# but EMPTY. Empty output => everything required is present and non-empty.
pf_missing_required() {
  local file="$1"; shift
  local v val
  local -a missing=()
  for v in "$@"; do
    if ! pf_env_has "${v}" "${file}"; then
      missing+=("${v}"); continue
    fi
    val="$(pf_env_value "${v}" "${file}")"
    [[ -z "${val}" ]] && missing+=("${v}")
  done
  ((${#missing[@]})) && printf '%s\n' "${missing[@]}"
  return 0
}

# --- Classify a run of scripts/check-secrets.sh ----------------------------
# Preflight does NOT re-implement secret strength — it runs check-secrets.sh and
# folds its result into the report. Given that script's exit code and combined
# output: a non-zero exit means a CRITICAL secret problem (=> FAIL); a zero exit
# with any "! " warning line means set-but-weak/empty-unused (=> WARN);
# otherwise PASS. Pure, so a test can feed a MOCKED check-secrets output.
pf_classify_secret_audit() {
  local rc="$1" out="$2"
  if [[ "${rc}" != "0" ]]; then echo "${PF_FAIL}"; return 0; fi
  if printf '%s\n' "${out}" | grep -qE '(^|[[:space:]])!([[:space:]]|$)'; then
    echo "${PF_WARN}"; return 0
  fi
  echo "${PF_PASS}"
}

# --- Numeric "more is better" classifier (disk, RAM) -----------------------
# VALUE < FAIL_AT => FAIL; VALUE < WARN_AT => WARN; otherwise PASS.
# All three are integers in the same unit. Non-numeric VALUE => WARN (can't
# tell — treated as a soft problem, never a false FAIL).
pf_classify_min() {
  local v="$1" warn_at="$2" fail_at="$3"
  if ! [[ "${v}" =~ ^[0-9]+$ ]]; then echo "${PF_WARN}"; return 0; fi
  if   (( v <  fail_at )); then echo "${PF_FAIL}"
  elif (( v <  warn_at )); then echo "${PF_WARN}"
  else                          echo "${PF_PASS}"
  fi
}

# --- CPU architecture verdict ----------------------------------------------
# The platform's images are pinned for linux/arm64 (Pi 5). A non-arm64 host is
# a WARN, not a FAIL: preflight still has value on an amd64 dev box.
pf_arch_verdict() {
  case "$1" in
    arm64|aarch64|aarch64_be|armv8*) echo "${PF_PASS}" ;;
    *)                               echo "${PF_WARN}" ;;
  esac
}

# --- Boot-media verdict from the device backing "/" ------------------------
# mmcblk* is an SD/eMMC card (write-wear risk for a 24/7 server) => WARN.
# nvme*/sd*/vd*/device-mapper look like an SSD/HDD => PASS.
# Anything else (overlay, tmpfs, unknown) => UNKNOWN (rendered as a soft WARN).
pf_sdcard_verdict() {
  case "$1" in
    *mmcblk*)                                   echo "${PF_WARN}" ;;
    *nvme*|*/sd[a-z]*|*/vd[a-z]*|*/mapper/*|*/dm-*) echo "${PF_PASS}" ;;
    *)                                          echo "UNKNOWN" ;;
  esac
}

# --- Image tags declared in a compose file ---------------------------------
# Echo each uncommented `image:` value (one per line), stripping quotes and
# trailing inline comments. Interpolated refs (containing `${`) are SKIPPED:
# in this platform those are the locally-BUILT images (e.g. the backup tool
# image), which have no registry tag to verify.
pf_extract_images() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  grep -E '^[[:space:]]*image:[[:space:]]*' "${file}" 2>/dev/null \
    | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' \
    | sed -E 's/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/' \
    | grep -v '\${' \
    || true
  return 0
}

# --- Does a `docker manifest inspect` blob advertise linux/arm64? -----------
# Tolerant string match (no jq dependency): a multi-arch manifest list carries
# a platform entry with architecture "arm64" and os "linux". Require both
# tokens so an amd64-only image is correctly rejected.
pf_manifest_arm64() {
  local json="$1"
  printf '%s' "${json}" | grep -qE '"architecture"[[:space:]]*:[[:space:]]*"arm64"' \
    && printf '%s' "${json}" | grep -qE '"os"[[:space:]]*:[[:space:]]*"linux"'
}

# --- Classify a failed `docker manifest inspect` from its stderr -----------
# Distinguishes a genuinely MISSING tag/repo (a real problem => FAIL upstream)
# from an OFFLINE/network error (no internet => WARN upstream, never a false
# FAIL). UNKNOWN for anything we can't place (treated as WARN upstream).
pf_classify_manifest_error() {
  local msg="$1"
  shopt -s nocasematch
  local result="UNKNOWN"
  if [[ "${msg}" =~ (no[[:space:]]such[[:space:]]manifest|manifest[[:space:]]unknown|manifest[[:space:]]for|not[[:space:]]found|MANIFEST_UNKNOWN|NAME_UNKNOWN|repository[[:space:]]name[[:space:]]not[[:space:]]known|unauthorized|denied|reference[[:space:]]does[[:space:]]not[[:space:]]exist) ]]; then
    result="MISSING"
  elif [[ "${msg}" =~ (no[[:space:]]such[[:space:]]host|dial[[:space:]]tcp|lookup[[:space:]]|timeout|timed[[:space:]]out|deadline[[:space:]]exceeded|connection[[:space:]]refused|network[[:space:]]is[[:space:]]unreachable|temporary[[:space:]]failure|could[[:space:]]not[[:space:]]resolve|TLS[[:space:]]handshake|i/o[[:space:]]timeout|EOF|context[[:space:]]canceled|proxyconnect) ]]; then
    result="OFFLINE"
  fi
  shopt -u nocasematch
  echo "${result}"
}

# --- Verdict for ONE image, using the (mockable) registry seam -------------
# Combines the registry lookup (pf_manifest_inspect — a SEAM, so tests stub it),
# the arm64 parse (pf_manifest_arm64) and the error classifier
# (pf_classify_manifest_error) into a single decision. Echoes "VERDICT|reason":
#   PASS  tag exists AND advertises linux/arm64
#   FAIL  tag exists but has NO linux/arm64  OR  tag/repo genuinely missing
#   WARN  registry unreachable / inconclusive (offline must never be a FAIL)
# This is the unit a test exercises by redefining pf_manifest_inspect.
pf_check_image() {
  local img="$1" json rc errf
  errf="$(mktemp)"
  json="$(pf_manifest_inspect "${img}" 2>"${errf}")"; rc=$?
  if [[ "${rc}" == "0" ]]; then
    if pf_manifest_arm64 "${json}"; then
      echo "PASS|tag exists and advertises linux/arm64"
    else
      echo "FAIL|tag exists but does NOT advertise linux/arm64"
    fi
  else
    case "$(pf_classify_manifest_error "$(cat "${errf}")")" in
      MISSING) echo "FAIL|tag/repo not found in the registry" ;;
      OFFLINE) echo "WARN|registry unreachable (offline); not verified" ;;
      *)       echo "WARN|registry check inconclusive; not verified" ;;
    esac
  fi
  rm -f "${errf}"
  return 0
}

# --- Container log-rotation verdict (Docker default log size caps) ----------
# Docker's default json-file log driver has NO size limit, so a chatty or
# crash-looping container can silently fill the SSD over weeks.
# infrastructure/docker-daemon.json.example bounds EVERY container at once by
# setting default log-opts (max-size + max-file). Given the daemon's EFFECTIVE
# default log DRIVER (from `docker info`) and the max-size/max-file it has
# configured (from daemon.json), decide whether logs are bounded:
#   PASS  'local' driver (rotates by default), OR json-file WITH both caps set
#   WARN  json-file (or unknown/other) without both caps — logs may be unbounded
# This is ADVISORY: it NEVER returns FAIL. Unbounded logs are a slow-burn risk,
# not a launch blocker, and the fix needs root + a daemon restart done out of band.
pf_logrotate_verdict() {
  local driver="$1" max_size="$2" max_file="$3"
  case "${driver}" in
    local)
      echo "PASS|'local' log driver rotates by default — container logs are bounded" ;;
    json-file)
      if [[ -n "${max_size}" && -n "${max_file}" ]]; then
        echo "PASS|json-file with default caps (max-size=${max_size}, max-file=${max_file}) — logs are bounded"
      else
        echo "WARN|json-file is the default driver but a default max-size/max-file cap is NOT set — container logs are unbounded and can fill the SSD; apply infrastructure/docker-daemon.json.example"
      fi ;;
    "")
      echo "WARN|could not determine the default Docker logging driver — verify container logs are size-bounded (see infrastructure/docker-daemon.json.example)" ;;
    *)
      echo "WARN|default log driver is '${driver}', not json-file/local — verify it bounds log size (see infrastructure/docker-daemon.json.example)" ;;
  esac
}

# --- Read ONE log-opt (max-size / max-file) from a daemon.json --------------
# Extracts the value of a log-opts key from the Docker daemon config WITHOUT a
# JSON parser (no jq dependency) — tolerant of spacing and of quoted ("3") or
# bare (3) values. Echoes the value, or "" when the file or key is absent.
# READ-ONLY: the file is only ever read, never written.
pf_daemon_log_opt() {
  local file="$1" key="$2" line val
  [[ -f "${file}" ]] || { printf ''; return 0; }
  line="$(grep -E "\"${key}\"[[:space:]]*:" "${file}" 2>/dev/null | head -n1 || true)"
  [[ -n "${line}" ]] || { printf ''; return 0; }
  val="${line#*:}"            # drop the key and the colon
  val="${val%%,*}"            # drop a trailing comma and anything after it
  val="$(printf '%s' "${val}" | tr -d ' \t"')"   # strip spaces, tabs, quotes
  printf '%s' "${val}"
}

# --- Host ports published by a compose file --------------------------------
# Echo each uncommented `- "H:C[/proto]"` mapping as "HOSTPORT/PROTO" (proto
# defaults to tcp). Emitting the protocol matters: `443:443` (tcp) and
# `443:443/udp` are the SAME service on different protocols and must NOT be
# reported as a collision. Commented bootstrap ports start with `#`, so they
# are ignored. Used to spot real host-port collisions across services.
pf_extract_host_ports() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  grep -E '^[[:space:]]*-[[:space:]]*"?[0-9]+:[0-9]+' "${file}" 2>/dev/null \
    | sed -E 's/^[[:space:]]*-[[:space:]]*"?//' \
    | awk '{
        host=$0; sub(/[^0-9].*/, "", host);     # leading digits = host port
        proto="tcp";
        if ($0 ~ /\/udp/)  proto="udp";
        else if ($0 ~ /\/sctp/) proto="sctp";
        print host "/" proto;
      }' \
    || true
  return 0
}

# --- Named volumes declared in a compose file ------------------------------
# Echo each volume name under the top-level `volumes:` block. State machine:
# enter the block on a column-0 `volumes:` line, leave it on the next column-0
# key, and emit indented `name:` lines in between (comments are skipped).
pf_extract_volumes() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  awk '
    /^volumes:[[:space:]]*$/ { inv=1; next }
    inv && /^[^[:space:]#]/  { inv=0 }
    inv && /^[[:space:]]+[A-Za-z0-9_.-]+:[[:space:]]*$/ {
      line=$0; sub(/:[[:space:]]*$/, "", line); gsub(/[[:space:]]/, "", line); print line
    }
  ' "${file}" 2>/dev/null || true
  return 0
}

# --- container_name values declared in a compose file ----------------------
# A container name never contains whitespace or '#', so everything from the
# first whitespace onward is a trailing inline comment and is dropped.
pf_extract_container_names() {
  local file="$1"
  [[ -f "${file}" ]] || return 0
  grep -E '^[[:space:]]*container_name:[[:space:]]*' "${file}" 2>/dev/null \
    | sed -E 's/^[[:space:]]*container_name:[[:space:]]*//; s/[[:space:]].*$//' \
    || true
  return 0
}

# --- Find duplicates among lines on stdin ----------------------------------
# Echo each value that appears more than once. Pure; used for both port and
# name collision detection.
pf_find_duplicates() {
  sort | uniq -d
}

# --- Map a running container's name-suffix to a component key --------------
# Container names are "<project>_<suffix>"; the caller strips the prefix and
# passes the suffix. Returns "" for anything not part of the known stack
# (e.g. a one-off generated project container).
pf_container_to_component() {
  case "$1" in
    caddy)                              echo "proxy" ;;
    portainer|uptime-kuma|watchtower)   echo "management" ;;
    postgres)                           echo "postgres" ;;
    mysql)                              echo "mysql" ;;
    mongo)                              echo "mongo" ;;
    redis)                              echo "redis" ;;
    pgadmin)                            echo "pgadmin" ;;
    adminer)                            echo "adminer" ;;
    mongo-express)                      echo "mongo-express" ;;
    keycloak|keycloak-db)               echo "auth" ;;
    n8n|n8n-db)                         echo "automation" ;;
    homepage)                           echo "dashboard" ;;
    verdaccio|nuget_cache|nuget-cache)  echo "cache" ;;
    backup)                             echo "backup" ;;
    *)                                  echo "" ;;
  esac
}

# ===========================================================================
# SECTION 2 — Component REGISTRY (data, not logic)
# ===========================================================================
# Ordered list (associative arrays are unordered) used for deterministic
# iteration and validation of --services values.
PF_ALL_COMPONENTS=(
  proxy management
  postgres mysql mongo redis
  pgadmin adminer mongo-express
  auth automation dashboard cache backup
)

# The always-on core checked by default.
PF_CORE_COMPONENTS=(proxy management)

# component -> compose files (space-separated, project-root-relative). Each
# always includes the base file so the shared networks resolve on `config`.
declare -A PF_COMPOSE=(
  [proxy]="infrastructure/docker-compose.yml services/proxy/proxy.compose.yml"
  [management]="infrastructure/docker-compose.yml infrastructure/management.compose.yml"
  [postgres]="infrastructure/docker-compose.yml services/databases/databases.compose.yml"
  [mysql]="infrastructure/docker-compose.yml services/databases/databases.compose.yml"
  [mongo]="infrastructure/docker-compose.yml services/databases/databases.compose.yml"
  [redis]="infrastructure/docker-compose.yml services/databases/databases.compose.yml"
  [pgadmin]="infrastructure/docker-compose.yml services/db-admin/db-admin.compose.yml"
  [adminer]="infrastructure/docker-compose.yml services/db-admin/db-admin.compose.yml"
  [mongo-express]="infrastructure/docker-compose.yml services/db-admin/db-admin.compose.yml"
  [auth]="infrastructure/docker-compose.yml services/auth/auth.compose.yml"
  [automation]="infrastructure/docker-compose.yml services/automation/automation.compose.yml"
  [dashboard]="infrastructure/docker-compose.yml services/dashboard/dashboard.compose.yml"
  [cache]="infrastructure/docker-compose.yml services/cache/cache.compose.yml"
  [backup]="infrastructure/docker-compose.yml services/backup/backup.compose.yml"
)

# component -> Compose profile required to bring it into scope ("" = none).
declare -A PF_PROFILE=(
  [postgres]="postgres"
  [mysql]="mysql"
  [mongo]="mongo"
  [redis]="redis"
  [pgadmin]="pgadmin"
  [adminer]="adminer"
  [mongo-express]="mongo-express"
  [cache]="cache"
  [backup]="backup"
)

# component -> REQUIRED .env variables (no compose default => the image needs
# them). Presence + non-empty is checked here; strength is left to
# check-secrets.sh. Components with only-defaulted vars are absent below.
declare -A PF_REQVARS=(
  [postgres]="POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB"
  [mysql]="MYSQL_ROOT_PASSWORD MYSQL_DATABASE MYSQL_USER MYSQL_PASSWORD"
  [mongo]="MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD MONGO_INITDB_DATABASE"
  [redis]="REDIS_PASSWORD"
  [pgadmin]="PGADMIN_DEFAULT_EMAIL PGADMIN_DEFAULT_PASSWORD"
  [mongo-express]="MONGO_INITDB_ROOT_USERNAME MONGO_INITDB_ROOT_PASSWORD ME_CONFIG_BASICAUTH_USERNAME ME_CONFIG_BASICAUTH_PASSWORD"
  [auth]="KC_DB_NAME KC_DB_USERNAME KC_DB_PASSWORD KC_BOOTSTRAP_ADMIN_USERNAME KC_BOOTSTRAP_ADMIN_PASSWORD"
  [automation]="N8N_DB_NAME N8N_DB_USERNAME N8N_DB_PASSWORD N8N_ENCRYPTION_KEY"
)

# Is NAME a known component key (or the "core" alias)?
pf_is_component() {
  local n="$1" c
  [[ "${n}" == "core" ]] && return 0
  for c in "${PF_ALL_COMPONENTS[@]}"; do
    [[ "${c}" == "${n}" ]] && return 0
  done
  return 1
}

# Named networks/volumes the platform declares (project-name prefixed at
# runtime). Networks use fixed names from .env; volumes are prefixed
# "<project>_". The orchestrator compares these against what already exists.
PF_NETWORK_VARS=(INTERNAL_NETWORK_NAME PROXY_NETWORK_NAME)

# ===========================================================================
# SECTION 3 — SEAMS (every external/system call lives behind one of these so
#             tests can redefine it; the orchestrator never calls the real
#             tools directly). Defaults are the real implementations.
# ===========================================================================

# Is a command available on PATH?
pf_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# The docker CLI. (Wrapped so tests can stub the whole thing.)
pf_docker() { command docker "$@"; }

# Is the Docker daemon reachable?
pf_docker_running() { pf_docker info >/dev/null 2>&1; }

# Is Docker Compose v2 (the `docker compose` plugin) available?
pf_compose_available() { pf_docker compose version >/dev/null 2>&1; }

# CPU architecture (e.g. aarch64, x86_64).
pf_uname_m() { uname -m 2>/dev/null || true; }

# Available kilobytes on the filesystem holding PATH.
pf_disk_avail_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

# Total / available RAM in MiB (from /proc/meminfo; portable enough for the Pi).
pf_mem_total_mb() { awk '/^MemTotal:/     {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true; }
pf_mem_avail_mb() { awk '/^MemAvailable:/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || true; }

# The device/source backing the root filesystem (best-effort).
pf_root_source() {
  if pf_have_cmd findmnt; then
    findmnt -n -o SOURCE / 2>/dev/null || true
  else
    awk '$2=="/"{print $1; exit}' /proc/mounts 2>/dev/null || true
  fi
}

# `docker compose config` for a merge: validates that the files PARSE. Pass the
# file list and optional profile as already-built argv. READ-ONLY.
pf_compose_config() { pf_docker compose "$@" config >/dev/null 2>&1; }

# `docker manifest inspect` for one image. JSON to stdout, errors to stderr,
# returns the docker exit code. READ-ONLY (no pull).
pf_manifest_inspect() { pf_docker manifest inspect "$1"; }

# Names of existing docker networks / volumes (one per line).
pf_existing_networks() { pf_docker network ls --format '{{.Name}}' 2>/dev/null || true; }
pf_existing_volumes()  { pf_docker volume  ls --format '{{.Name}}' 2>/dev/null || true; }

# Running container names (one per line). READ-ONLY.
pf_running_container_names() { pf_docker ps --format '{{.Names}}' 2>/dev/null || true; }

# The daemon's EFFECTIVE default logging driver (read-only). Empty on failure.
pf_docker_log_driver() { pf_docker info --format '{{.LoggingDriver}}' 2>/dev/null || true; }

# Path to the live Docker daemon config, where default log-opts live. Override
# with PF_DAEMON_JSON (tests point this at a fixture). READ-ONLY (only read).
pf_daemon_json_path() { printf '%s' "${PF_DAEMON_JSON:-/etc/docker/daemon.json}"; }
