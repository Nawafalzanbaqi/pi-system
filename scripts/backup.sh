#!/usr/bin/env bash
# ===========================================================================
# pi-system — backup entrypoint (manual)
# ---------------------------------------------------------------------------
# The single front door for the encrypted backup system. It drives the
# profile-gated `backup` container (services/backup) and the host-side restore
# drill, so an operator never has to remember the raw docker/compose commands.
#
# Usage:
#     ./scripts/backup.sh <command> [options]
#
#   init-key            Generate the age encryption key (once). Backups are
#                       encrypted to this key; KEEP A COPY OFFLINE — without it
#                       NO backup can ever be restored. Refuses to overwrite an
#                       existing key unless --force.
#   now                 Run a backup NOW (every running database + config),
#                       encrypted, with retention applied, then copy offsite
#                       (when BACKUP_OFFSITE_* is configured).
#   offsite             Copy the existing encrypted backups offsite via rclone
#                       (BACKUP_OFFSITE_*). No-op unless configured; the remote
#                       only ever receives encrypted artifacts. `now` calls this.
#   list                List the encrypted backups on disk (daily + weekly).
#   verify [options]    Run the TESTED-RESTORE drill into disposable throwaway
#                       containers (delegates to scripts/backup-verify.sh). Never
#                       touches live data. Pass --help for its options.
#   restore --dry-run <archive>
#                       PLAN-ONLY restore check. Validates a backup run against its
#                       manifest (artifacts present, sizes + checksums match, age
#                       key available, schema known) and prints a plan + a single
#                       OVERALL: SAFE-TO-RESTORE / NOT-SAFE line. Touches NO live
#                       data and NO container. The REAL restore is ./scripts/restore.sh.
#   status              Show the result of the last backup and last restore drill,
#                       and warn if either is stale.
#
# Examples:
#     ./scripts/backup.sh init-key
#     ./scripts/backup.sh now
#     ./scripts/backup.sh list
#     ./scripts/backup.sh verify
#     ./scripts/backup.sh status
#
# The real, operator-confirmed restore into LIVE databases is a SEPARATE,
# deliberately guarded script: ./scripts/restore.sh  (never run automatically).
# Schedule daily backups + the weekly drill with: ./scripts/backup-install-cron.sh
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[backup]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
BACKUP_COMPOSE="services/backup/backup.compose.yml"
VERIFY_SCRIPT="scripts/backup-verify.sh"

# Pure-logic restore-planning + notifier helpers (offline-testable; no Docker).
BACKUP_LIB="${SCRIPT_DIR}/lib/backup-lib.sh"
# shellcheck source=lib/backup-lib.sh
[[ -f "${BACKUP_LIB}" ]] && source "${BACKUP_LIB}"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/backup.sh <command> [options]

  init-key          Generate the age encryption key (once). KEEP A COPY OFFLINE.
  now               Run an encrypted backup now (running DBs + config); then
                    copy offsite if BACKUP_OFFSITE_* is configured.
  offsite           Copy the encrypted backups offsite via rclone (BACKUP_OFFSITE_*).
                    No-op unless configured; the remote only sees encrypted data.
  list              List the encrypted backups on disk (daily + weekly).
  verify [options]  Run the TESTED-RESTORE drill into disposable containers
                    (scripts/backup-verify.sh). Never touches live data.
  restore --dry-run <archive>
                    PLAN-ONLY check: validate a backup run against its manifest and
                    print a plan + OVERALL: SAFE-TO-RESTORE / NOT-SAFE. Changes nothing.
  status            Show last backup + last drill result; warn if stale.

Examples:
  ./scripts/backup.sh init-key
  ./scripts/backup.sh now
  ./scripts/backup.sh verify
  ./scripts/backup.sh status

The guarded real restore into LIVE data is separate: ./scripts/restore.sh
See docs/README.md "Backup & restore".
EOF
}

# --- Read a value from .env WITHOUT sourcing it ----------------------------
env_get() {
  local key="$1" line val
  line="$(grep -E "^[[:space:]]*${key}=" .env 2>/dev/null | tail -n1 || true)"
  val="${line#*=}"
  val="${val%$'\r'}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  if [[ "${val}" == \"*\" && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "${val}" == \'*\' && ${#val} -ge 2 ]]; then
    val="${val:1:${#val}-2}"
  fi
  printf '%s' "${val}"
}

# Resolve a (possibly relative) path against the project root.
resolve_path() {
  case "$1" in
    /*) printf '%s' "$1" ;;
    *)  printf '%s/%s' "${PROJECT_ROOT}" "${1#./}" ;;
  esac
}

# --- Common preconditions --------------------------------------------------
require_env() {
  if [[ ! -f ".env" ]]; then
    err ".env not found. Run ./scripts/setup.sh first, then edit .env."
    exit 1
  fi
}
require_compose_files() {
  local f
  for f in "${BASE_COMPOSE}" "${BACKUP_COMPOSE}"; do
    if [[ ! -f "${f}" ]]; then
      err "Missing required file: ${f}"
      exit 1
    fi
  done
}
require_docker() {
  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
    exit 1
  fi
}

# Build the compose invocation (base + backup files, backup profile).
compose() {
  docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
    -f "${BASE_COMPOSE}" -f "${BACKUP_COMPOSE}" --profile backup "$@"
}

# Encryption-configured? (recipients set OR a non-empty identity file present).
KEY_FILE_REL="$(env_get BACKUP_AGE_KEY_FILE)"; KEY_FILE_REL="${KEY_FILE_REL:-./secrets/backup/age-identity.key}"
KEY_FILE_ABS="$(resolve_path "${KEY_FILE_REL}")"
RECIPIENTS="$(env_get BACKUP_AGE_RECIPIENTS)"
BACKUP_DIR_REL="$(env_get BACKUP_DIR)"; BACKUP_DIR_REL="${BACKUP_DIR_REL:-./data/backups}"
BACKUP_DIR_ABS="$(resolve_path "${BACKUP_DIR_REL}")"

encryption_ready() {
  [[ -n "${RECIPIENTS}" ]] && return 0
  [[ -s "${KEY_FILE_ABS}" ]] && return 0
  return 1
}

# ===========================================================================
# Commands
# ===========================================================================
cmd_init_key() {
  local force=0
  [[ "${1:-}" == "--force" ]] && force=1
  require_env

  if [[ -s "${KEY_FILE_ABS}" && "${force}" -ne 1 ]]; then
    err "An age identity already exists at ${KEY_FILE_REL}."
    err "Refusing to overwrite it (doing so would make existing backups"
    err "unrecoverable). Re-run with --force ONLY if you are sure."
    exit 1
  fi

  mkdir -p "$(dirname "${KEY_FILE_ABS}")"
  local tmp; tmp="$(mktemp)"

  if command -v age-keygen >/dev/null 2>&1; then
    log "Generating an age identity with the host's age-keygen ..."
    age-keygen -o "${tmp}" 2>/dev/null
  else
    require_compose_files
    require_docker
    log "Building the backup image (first time only) ..."
    compose build backup >/dev/null
    log "Generating an age identity via the backup container ..."
    # age-keygen writes the identity to stdout; capture it on the host.
    compose run --rm --no-deps -T --entrypoint age-keygen backup >"${tmp}" 2>/dev/null
  fi

  if [[ ! -s "${tmp}" ]]; then
    rm -f "${tmp}"
    err "Key generation produced no output. Aborting."
    exit 1
  fi
  mv -f "${tmp}" "${KEY_FILE_ABS}"
  chmod 600 "${KEY_FILE_ABS}" 2>/dev/null || warn "Could not chmod 600 ${KEY_FILE_REL}."

  local pub
  pub="$(grep -i 'public key:' "${KEY_FILE_ABS}" | sed -E 's/.*public key:[[:space:]]*//I' | tr -d '\r')"
  echo
  log "age identity written to ${KEY_FILE_REL} (mode 600, git-ignored)."
  [[ -n "${pub}" ]] && log "Public recipient: ${pub}"
  warn "CRITICAL: copy this key file somewhere SAFE and OFFLINE now."
  warn "It is the ONLY thing that can decrypt your backups. If the Pi's SSD"
  warn "dies and you have not kept a copy, every backup is unrecoverable."
  log  "Nothing else to set — backups will use this key automatically."
}

# notify_backup_failure <label> <body> — surface a FAILURE through the swappable
# notifier seam so a SILENT scheduled-backup or offsite-push failure cannot go
# unnoticed (the worst backup failure is the one you find when you need it). Gated
# by BACKUP_NOTIFY_CMD in .env (default: the bundled Telegram notifier; "off"
# disables). The notifier is itself gated + best-effort — this NEVER fails the backup.
notify_backup_failure() {
  local label="$1" body="$2" cmd
  declare -F bk_notify_failure >/dev/null 2>&1 || return 0
  cmd="$(env_get BACKUP_NOTIFY_CMD)"; cmd="${cmd:-./scripts/notify-telegram.sh}"
  [[ "${cmd}" == "off" || -z "${cmd}" ]] && return 0
  cmd="$(resolve_path "${cmd}")"
  bk_notify_failure "${cmd}" "${label}" "${body}"
}

cmd_now() {
  require_env
  require_compose_files
  require_docker

  if ! encryption_ready; then
    err "Backup encryption is not configured."
    err "Generate the key first:  ./scripts/backup.sh init-key"
    exit 1
  fi

  mkdir -p "${BACKUP_DIR_ABS}" "$(dirname "${KEY_FILE_ABS}")"

  log "Building the backup image (cached after first build) ..."
  compose build backup
  log "Running the encrypted backup ..."
  # run --rm: one-shot job; the profile keeps it from ever auto-starting. Capture the
  # exit code (do NOT let set -e abort) so a failure can be SURFACED, not swallowed.
  local backup_rc=0
  compose run --rm backup || backup_rc=$?
  if (( backup_rc != 0 )); then
    err "Backup run FAILED (exit ${backup_rc}). See ${BACKUP_DIR_REL}/status/backup.log."
    notify_backup_failure "backup-failed" \
      "BACKUP FAILED (exit ${backup_rc}) at $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname 2>/dev/null || echo '?'). See ${BACKUP_DIR_REL}/status/backup.log and last-backup.json."
  else
    log "Done. Inspect with:  ./scripts/backup.sh list"
  fi

  # Best-effort OFFSITE copy of the just-written encrypted artifacts. A no-op unless
  # BACKUP_OFFSITE_* is configured; a failure is surfaced loudly + notified but does NOT
  # by itself fail the local backup — the local artifacts are the primary copy.
  if ! cmd_offsite; then
    warn "Offsite copy did not complete (see above). The LOCAL backup state is unchanged."
    notify_backup_failure "offsite-failed" \
      "OFFSITE copy FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname 2>/dev/null || echo '?'). Local backups are intact; fix connectivity/config and run: ./scripts/backup.sh offsite"
  fi

  # A failed backup must PROPAGATE so cron logs + 'backup.sh status' reflect it.
  (( backup_rc == 0 )) || return 1
}

# Record the outcome of an offsite copy so it is observable (mirrors last-backup.json).
# Writes only non-secret fields — the remote PATH (not credentials) and a short reason.
write_offsite_status() {
  local ok="$1" errmsg="$2" remote="$3" sdir esc_e esc_r
  sdir="${BACKUP_DIR_ABS}/status"
  mkdir -p "${sdir}" 2>/dev/null || true
  esc_e="${errmsg//\\/\\\\}"; esc_e="${esc_e//\"/\\\"}"
  esc_r="${remote//\\/\\\\}"; esc_r="${esc_r//\"/\\\"}"
  printf '{"ts":"%s","ok":%s,"type":"rclone","remote":"%s","error":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${ok}" "${esc_r}" "${esc_e}" \
    > "${sdir}/last-offsite.json" 2>/dev/null || true
}

# cmd_offsite — copy the ALREADY-ENCRYPTED local backups offsite via the configured
# tool (currently rclone). Gated entirely on BACKUP_OFFSITE_* (blank = no-op). The
# destination only ever receives age-encrypted `.age` artifacts — never plaintext, never
# the age key. Honours BACKUP_OFFSITE_DRYRUN=1 (prints the plan, runs nothing). Exit:
# 0 = pushed or cleanly skipped; 1 = configured but the copy failed; 2 = misconfigured.
cmd_offsite() {
  require_env
  local type remote conf conf_abs
  type="$(env_get BACKUP_OFFSITE_TYPE)"
  remote="$(env_get BACKUP_OFFSITE_REMOTE)"
  conf="$(env_get BACKUP_OFFSITE_CONFIG)"; conf="${conf:-./secrets/backup/rclone.conf}"

  if [[ -z "${type}" ]]; then
    log "Offsite copy not configured (BACKUP_OFFSITE_TYPE blank) — skipping (local backups unaffected)."
    return 0
  fi
  if [[ "${type}" != "rclone" ]]; then
    err "Unsupported BACKUP_OFFSITE_TYPE '${type}'. Only 'rclone' is supported."
    return 2
  fi
  if [[ -z "${remote}" ]]; then
    err "BACKUP_OFFSITE_REMOTE is empty (e.g. b2:my-pi-backups). Set it in .env."
    return 2
  fi
  conf_abs="$(resolve_path "${conf}")"
  # rclone COPY (never deletes at the destination — a local issue can't erase the
  # offsite copy). The transfer is of the encrypted backup tree as-is.
  local -a rc=(rclone --config "${conf_abs}" copy "${BACKUP_DIR_ABS}" "${remote}" --transfers 4 --checkers 8)

  if [[ "${BACKUP_OFFSITE_DRYRUN:-0}" == "1" ]]; then
    log "[dry-run] offsite plan: ${rc[*]}"
    return 0
  fi
  if [[ ! -d "${BACKUP_DIR_ABS}" ]]; then
    warn "No local backups at ${BACKUP_DIR_REL} yet — nothing to copy offsite."
    return 0
  fi
  if ! command -v rclone >/dev/null 2>&1; then
    err "rclone is not installed. Install it (https://rclone.org/install/ or 'sudo apt-get install -y rclone'),"
    err "then create the remote with:  rclone --config ${conf} config"
    write_offsite_status false "rclone not installed" "${remote}"
    return 2
  fi
  if [[ ! -f "${conf_abs}" ]]; then
    err "rclone config not found: ${conf}. Create the remote with:  rclone --config ${conf} config"
    write_offsite_status false "rclone config missing" "${remote}"
    return 2
  fi
  log "Copying encrypted backups offsite via rclone -> ${remote} ..."
  if "${rc[@]}"; then
    log "✓ Offsite copy complete (destination holds only encrypted artifacts)."
    write_offsite_status true "" "${remote}"
    return 0
  fi
  err "✗ Offsite copy FAILED. Local backups are intact; fix connectivity/config and retry:"
  err "    ./scripts/backup.sh offsite"
  write_offsite_status false "rclone copy failed" "${remote}"
  return 1
}

cmd_list() {
  require_env
  if [[ ! -d "${BACKUP_DIR_ABS}" ]]; then
    warn "No backups yet (${BACKUP_DIR_REL} does not exist). Run: ./scripts/backup.sh now"
    return 0
  fi
  local tier dir count okc failc
  for tier in daily weekly; do
    echo
    log "${tier^} backups in ${BACKUP_DIR_REL}/${tier}:"
    if ! ls -1d "${BACKUP_DIR_ABS}/${tier}"/*/ >/dev/null 2>&1; then
      printf '  (none)\n'
      continue
    fi
    while read -r dir; do
      [[ -z "${dir}" ]] && continue
      count="$(find "${dir}" -maxdepth 1 -name '*.age' | wc -l | tr -d ' ')"
      okc=0; failc=0
      if [[ -f "${dir}manifest.txt" ]]; then
        okc="$(grep -c '|ok|' "${dir}manifest.txt" 2>/dev/null || echo 0)"
        failc="$(grep -c '|failed|' "${dir}manifest.txt" 2>/dev/null || echo 0)"
      fi
      printf '  %-26s  %5s  %s artifacts (%s ok, %s failed)\n' \
        "$(basename "${dir%/}")" "$(du -sh "${dir}" 2>/dev/null | cut -f1)" "${count}" "${okc}" "${failc}"
    done < <(ls -1dt "${BACKUP_DIR_ABS}/${tier}"/*/ 2>/dev/null)
  done
  echo
  log "Total on disk: $(du -sh "${BACKUP_DIR_ABS}" 2>/dev/null | cut -f1)"
}

cmd_status() {
  require_env
  local sdir="${BACKUP_DIR_ABS}/status"
  local f age_h
  for f in last-backup.json last-verify.json; do
    echo
    if [[ -f "${sdir}/${f}" ]]; then
      log "${sdir#${PROJECT_ROOT}/}/${f}:"
      cat "${sdir}/${f}"
      # Staleness: warn if older than ~26h (backup) / ~8 days (drill).
      age_h="$(( ( $(date +%s) - $(stat -c %Y "${sdir}/${f}" 2>/dev/null || echo 0) ) / 3600 ))"
      if [[ "${f}" == "last-backup.json" && "${age_h}" -gt 26 ]]; then
        warn "Last backup is ${age_h}h old (> 26h) — has the daily schedule run?"
      fi
      if [[ "${f}" == "last-verify.json" && "${age_h}" -gt 192 ]]; then
        warn "Last restore drill is ${age_h}h old (> 8 days) — has the weekly drill run?"
      fi
    else
      warn "No ${f} yet (the corresponding job has not run)."
    fi
  done

  # Offsite copy status — only reported when offsite is configured or has run, so
  # operators not using offsite are never nagged about it.
  if [[ -f "${sdir}/last-offsite.json" ]]; then
    echo
    log "${sdir#${PROJECT_ROOT}/}/last-offsite.json:"
    cat "${sdir}/last-offsite.json"
    age_h="$(( ( $(date +%s) - $(stat -c %Y "${sdir}/last-offsite.json" 2>/dev/null || echo 0) ) / 3600 ))"
    [[ "${age_h}" -gt 26 ]] && warn "Last offsite copy is ${age_h}h old (> 26h) — is the daily 'now' running?"
  elif [[ -n "$(env_get BACKUP_OFFSITE_TYPE)" ]]; then
    echo
    warn "Offsite is configured but no last-offsite.json yet — run './scripts/backup.sh offsite' (or 'now')."
  fi
}

# cmd_restore — PLAN-ONLY restore validation. `restore --dry-run <archive>`
# validates a backup run against its manifest and prints a plan + a single
# OVERALL: SAFE-TO-RESTORE / NOT-SAFE verdict, so an operator can TRUST a backup
# BEFORE relying on it. It touches NO live data and NO container. The REAL,
# destructive restore is the deliberately-guarded, separate ./scripts/restore.sh.
cmd_restore() {
  require_env
  local dry=0 archive=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run) dry=1; shift ;;
      -h|--help)
        printf 'Usage: ./scripts/backup.sh restore --dry-run <run-dir-or-archive>\n' >&2
        printf 'Validates a backup against its manifest and prints a SAFE/NOT-SAFE plan.\n' >&2
        printf 'Changes nothing. The REAL restore is: ./scripts/restore.sh\n' >&2
        return 0 ;;
      --*) err "Unknown option for restore: '$1'."; return 1 ;;
      *) if [[ -z "${archive}" ]]; then archive="$1"; shift; else err "Unexpected extra argument: '$1'."; return 1; fi ;;
    esac
  done

  if (( dry != 1 )); then
    err "backup.sh restore only PLANS a restore — pass --dry-run."
    err "The REAL restore into LIVE data is the deliberately-guarded, separate script:"
    err "    ./scripts/restore.sh --engine <target> --confirm"
    return 2
  fi
  if ! declare -F bk_plan_restore >/dev/null 2>&1; then
    err "Missing ${BACKUP_LIB#${PROJECT_ROOT}/} — cannot plan a restore."
    return 1
  fi
  if [[ -z "${archive}" ]]; then
    err "restore --dry-run needs a backup run directory (or an artifact inside one)."
    err "List them with:  ./scripts/backup.sh list"
    return 1
  fi

  # Resolve the target to a backup RUN DIRECTORY (accept a dir, the manifest, or
  # any artifact inside one).
  local target; target="$(resolve_path "${archive}")"
  local run_dir
  if [[ -d "${target}" ]]; then run_dir="${target%/}"
  elif [[ -f "${target}" ]]; then run_dir="$(cd "$(dirname "${target}")" && pwd)"
  else err "No such backup run directory or archive: ${archive}"; return 1; fi

  # Is the age identity available at all? (presence only — the key is never read here).
  local key_state="missing"; [[ -s "${KEY_FILE_ABS}" ]] && key_state="present"

  # Best-effort, CHEAP decryptability proof — ONLY if the host has the `age` CLI and
  # the key. It decrypts the SMALLEST ok artifact to /dev/null (no container, no live
  # data). When age is absent it is skipped; the full end-to-end proof is backup.sh verify.
  local decrypt_state="skipped" smallest
  if [[ "${key_state}" == "present" ]] && command -v age >/dev/null 2>&1 && [[ -f "${run_dir}/manifest.txt" ]]; then
    smallest="$(awk -F'|' '!/^#/ && $4=="ok" && $5 ~ /^[0-9]+$/ {print $5"|"$3}' "${run_dir}/manifest.txt" 2>/dev/null | sort -n | head -1 | cut -d'|' -f2)"
    if [[ -n "${smallest}" && -f "${run_dir}/${smallest}" ]]; then
      if age -d -i "${KEY_FILE_ABS}" "${run_dir}/${smallest}" >/dev/null 2>&1; then
        decrypt_state="ok"
      else
        decrypt_state="failed"
      fi
    fi
  fi

  echo
  if bk_plan_restore "${run_dir}" "${key_state}" "${decrypt_state}"; then
    echo
    log "PLAN ONLY — nothing was changed. To actually restore (this OVERWRITES live data):"
    log "    ./scripts/restore.sh --engine <target> --run ${run_dir#${PROJECT_ROOT}/} --confirm"
    return 0
  fi
  echo
  err "This backup is NOT safe to rely on as-is — resolve the PROBLEM(s) above before restoring."
  return 1
}

# ===========================================================================
# Dispatch
# ===========================================================================
if [[ $# -lt 1 ]]; then
  err "A command is required."
  usage
  exit 1
fi
COMMAND="$1"; shift || true

case "${COMMAND}" in
  init-key) cmd_init_key "${1:-}" ;;
  now)      cmd_now ;;
  offsite)  cmd_offsite ;;
  list)     cmd_list ;;
  restore)  cmd_restore "$@" ;;
  status)   cmd_status ;;
  verify)
    if [[ ! -x "${VERIFY_SCRIPT}" && ! -f "${VERIFY_SCRIPT}" ]]; then
      err "Missing ${VERIFY_SCRIPT}."
      exit 1
    fi
    exec bash "${VERIFY_SCRIPT}" "$@"
    ;;
  -h|--help|help) usage ;;
  *)
    err "Unknown command: '${COMMAND}'."
    usage
    exit 1
    ;;
esac
