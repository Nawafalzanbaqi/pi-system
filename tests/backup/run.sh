#!/usr/bin/env bash
# ===========================================================================
# pi-system — BACKUP test harness (offline: no Docker / age / rclone / network)
# ---------------------------------------------------------------------------
# The encrypted backup + restore-drill themselves need Docker and run on the Pi,
# so they are NOT exercised here. What IS offline-testable — and what this suite
# locks in — is the host-side wiring that has no Docker dependency:
#   * every backup script parses (bash -n),
#   * the OFFSITE rclone push: its gating (unconfigured -> clean no-op; unsupported
#     type / empty remote -> refused) and its DRY-RUN plan (the exact rclone argv),
#     proven WITHOUT rclone installed, and
#   * the wiring: `now` triggers the offsite copy; `offsite` is a real subcommand;
#     the push uses `copy` (never deletes the destination) of the ENCRYPTED tree.
#
# Usage:   ./tests/backup/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # NOT -e: run every check, then tally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BACKUP="${PROJECT_ROOT}/scripts/backup.sh"
BACKUP_LIB="${PROJECT_ROOT}/scripts/lib/backup-lib.sh"
VERIFY="${PROJECT_ROOT}/scripts/backup-verify.sh"
DO_BACKUP="${PROJECT_ROOT}/services/backup/do-backup.sh"

# Source the pure-logic helpers under test (planner + manifest readers + notify seam).
# shellcheck source=../../scripts/lib/backup-lib.sh
[[ -f "${BACKUP_LIB}" ]] && source "${BACKUP_LIB}"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; O=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; O=''
fi
tests_run=0; tests_failed=0; tests_skipped=0
_pass() { printf '  %s✓%s %s\n' "${G}" "${O}" "$1"; }
_fail() { printf '  %s✗%s %s\n' "${R}" "${O}" "$1"; tests_failed=$((tests_failed+1)); }
section() { printf '\n%s== %s ==%s\n' "${C}" "$1" "${O}"; }
ok()  { tests_run=$((tests_run+1)); if "${@:2}"; then _pass "$1"; else _fail "$1 (expected success)"; fi; }
no()  { tests_run=$((tests_run+1)); if "${@:2}"; then _fail "$1 (expected failure)"; else _pass "$1"; fi; }
has() { tests_run=$((tests_run+1)); case "$2" in *"$3"*) _pass "$1" ;; *) _fail "$1 — [$2] missing [$3]" ;; esac; }
fhas(){ tests_run=$((tests_run+1)); if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then _pass "$1"; else _fail "$1 — [$2] missing [$3]"; fi; }

# Build a throwaway project (backup.sh + a crafted .env + an empty backups dir) so the
# script's own PROJECT_ROOT resolution + .env reading run exactly as on the Pi.
mkproj() {
  local d; d="$(mktemp -d 2>/dev/null || echo "${SCRIPT_DIR}/.bk.$$")"
  mkdir -p "${d}/scripts/lib" "${d}/data/backups"
  cp "${BACKUP}" "${d}/scripts/backup.sh"
  [[ -f "${BACKUP_LIB}" ]] && cp "${BACKUP_LIB}" "${d}/scripts/lib/backup-lib.sh"
  cp "${PROJECT_ROOT}/.env.example" "${d}/.env"
  printf '%s' "${d}"
}
setkv() { sed -i -E "s|^${2}=.*|${2}=${3}|" "${1}/.env"; }
runoff() { OUT="$(cd "${1}" && shift; "$@" 2>&1)"; RC=$?; }   # runoff <dir> <env...> bash scripts/backup.sh offsite

# mkrun <run_dir> [schema] — build a VALID backup run directory: two dummy
# "encrypted" artifacts + a manifest whose byte sizes + SHA-256s genuinely match
# them (so the planner's integrity check passes). No Docker / age needed.
mkrun() {
  local rd="$1" schema="${2:-1}" s1 b1 s2 b2
  mkdir -p "${rd}"
  printf 'pg-cipher-bytes\n'      > "${rd}/pg.postgres.sql.gz.age"
  printf 'config-cipher-bytes\n'  > "${rd}/config.tar.gz.age"
  s1="$(sha256sum "${rd}/pg.postgres.sql.gz.age" | cut -d' ' -f1)"; b1="$(stat -c '%s' "${rd}/pg.postgres.sql.gz.age" 2>/dev/null || stat -f '%z' "${rd}/pg.postgres.sql.gz.age")"
  s2="$(sha256sum "${rd}/config.tar.gz.age"     | cut -d' ' -f1)"; b2="$(stat -c '%s' "${rd}/config.tar.gz.age" 2>/dev/null || stat -f '%z' "${rd}/config.tar.gz.age")"
  {
    echo "# pi-system backup manifest"
    echo "# schema: ${schema}"
    echo "# run: 20260526-000000"
    echo "# created_at: 2026-05-26T00:00:00Z"
    echo "# age_recipient: age1exampledummyrecipient000000000000000000000000000000"
    echo "# fields: kind|label|file|status|bytes|sha256"
    echo "pg|postgres|pg.postgres.sql.gz.age|ok|${b1}|${s1}"
    echo "config|config|config.tar.gz.age|ok|${b2}|${s2}"
  } > "${rd}/manifest.txt"
}

# ===========================================================================
section "INTEGRITY — every backup script parses"
# ---------------------------------------------------------------------------
for f in scripts/backup.sh scripts/backup-verify.sh scripts/restore.sh \
         scripts/backup-install-cron.sh services/backup/do-backup.sh; do
  tests_run=$((tests_run+1))
  if [[ -f "${PROJECT_ROOT}/${f}" ]]; then
    if bash -n "${PROJECT_ROOT}/${f}" 2>/dev/null; then _pass "syntax ok: ${f}"; else _fail "syntax error: ${f}"; fi
  else _fail "missing: ${f}"; fi
done

# ===========================================================================
section "OFFSITE — gating: unconfigured no-op, unsupported/empty refused"
# ---------------------------------------------------------------------------
D="$(mkproj)"
# .env.example ships BACKUP_OFFSITE_* blank -> a clean no-op (rc 0).
OUT="$(cd "${D}" && bash scripts/backup.sh offsite 2>&1)"; RC=$?
ok "unconfigured offsite is a clean no-op (rc 0)" test "${RC}" -eq 0
has "unconfigured offsite says it skipped" "${OUT}" "not configured"
# Unsupported tool -> rc 2.
setkv "${D}" BACKUP_OFFSITE_TYPE s3sync
OUT="$(cd "${D}" && bash scripts/backup.sh offsite 2>&1)"; RC=$?
ok "unsupported BACKUP_OFFSITE_TYPE refused (rc 2)" test "${RC}" -eq 2
has "unsupported type names rclone as the only option" "${OUT}" "Only 'rclone'"
# rclone selected but no remote -> rc 2.
setkv "${D}" BACKUP_OFFSITE_TYPE rclone
setkv "${D}" BACKUP_OFFSITE_REMOTE ""
OUT="$(cd "${D}" && bash scripts/backup.sh offsite 2>&1)"; RC=$?
ok "rclone without a remote refused (rc 2)" test "${RC}" -eq 2
has "empty-remote error is actionable" "${OUT}" "BACKUP_OFFSITE_REMOTE is empty"
rm -rf "${D}" 2>/dev/null || true

# ===========================================================================
section "OFFSITE — dry-run plan is correct (no rclone needed)"
# ---------------------------------------------------------------------------
D="$(mkproj)"
setkv "${D}" BACKUP_OFFSITE_TYPE rclone
setkv "${D}" BACKUP_OFFSITE_REMOTE b2:my-pi-backups
OUT="$(cd "${D}" && BACKUP_OFFSITE_DRYRUN=1 bash scripts/backup.sh offsite 2>&1)"; RC=$?
ok "dry-run exits 0 without running rclone" test "${RC}" -eq 0
has "dry-run prints a plan" "${OUT}" "[dry-run] offsite plan:"
has "plan invokes rclone with the config" "${OUT}" "rclone --config"
has "plan uses copy (never deletes the destination)" "${OUT}" " copy "
has "plan targets the configured remote" "${OUT}" "b2:my-pi-backups"
# It must NEVER use a destructive verb (sync/delete/purge) at the destination.
no "plan never uses a destructive rclone verb" bash -c 'printf "%s" "$1" | grep -Eq " (sync|delete|purge|deletefile|rmdir) "' _ "${OUT}"
rm -rf "${D}" 2>/dev/null || true

# ===========================================================================
section "WIRING — offsite is a subcommand, runs after a backup, observable"
# ---------------------------------------------------------------------------
fhas "backup.sh dispatches the offsite subcommand"  "${BACKUP}" "offsite)  cmd_offsite"
fhas "backup.sh now triggers the offsite copy"      "${BACKUP}" "if ! cmd_offsite; then"
fhas "offsite outcome is recorded (last-offsite.json)" "${BACKUP}" "last-offsite.json"
fhas "offsite reads BACKUP_OFFSITE_TYPE from .env"  "${BACKUP}" "BACKUP_OFFSITE_TYPE"
fhas ".env.example documents the offsite remote"    "${PROJECT_ROOT}/.env.example" "BACKUP_OFFSITE_REMOTE="

# ===========================================================================
section "MANIFEST — do-backup writes a verifiable integrity manifest"
# ---------------------------------------------------------------------------
fhas "manifest carries a schema version"            "${DO_BACKUP}" '# schema: ${MANIFEST_SCHEMA}'
fhas "manifest carries a creation timestamp"        "${DO_BACKUP}" '# created_at:'
fhas "manifest records the age recipient fingerprint" "${DO_BACKUP}" '# age_recipient:'
fhas "each member carries a sha256 checksum"        "${DO_BACKUP}" 'sha256sum'
# The schema do-backup WRITES must equal the schema the planner SUPPORTS (no drift).
DB_SCHEMA="$(grep -E '^MANIFEST_SCHEMA=' "${DO_BACKUP}" | head -1 | cut -d= -f2 | tr -d '[:space:]')"
ok  "do-backup schema matches the planner's supported schema" test "${DB_SCHEMA}" = "${BK_SUPPORTED_MANIFEST_SCHEMA}"
# bk_manifest_get reads header fields — including a value that itself contains ':'.
PD="$(mktemp -d)"; RD="${PD}/run"; mkrun "${RD}" 1
has "bk_manifest_get reads the schema"              "$(bk_manifest_get "${RD}/manifest.txt" schema)" "1"
has "bk_manifest_get reads a colon-bearing timestamp" "$(bk_manifest_get "${RD}/manifest.txt" created_at)" "2026-05-26T00:00:00Z"
has "bk_manifest_get reads the age recipient"       "$(bk_manifest_get "${RD}/manifest.txt" age_recipient)" "age1exampledummyrecipient"
# The planner surfaces those fields in its plan (so an operator sees provenance).
OUT="$(bk_plan_restore "${RD}" present 2>&1)"
has "plan shows the manifest schema"                "${OUT}" "manifest schema : 1"
has "plan shows the age recipient"                  "${OUT}" "age recipient   : age1exampledummyrecipient"
rm -rf "${PD}"

# ===========================================================================
section "PLAN — planRestore verdicts on fixture manifests (offline, no Docker)"
# ---------------------------------------------------------------------------
tests_run=$((tests_run+1))
if declare -F bk_plan_restore >/dev/null 2>&1; then _pass "backup-lib.sh sourced (bk_plan_restore present)"
else _fail "backup-lib.sh did not provide bk_plan_restore"; fi

# (a) A good manifest with the key present -> SAFE, no problems, no warnings.
PD="$(mktemp -d)"; RD="${PD}/run"; mkrun "${RD}" 1
OUT="$(bk_plan_restore "${RD}" present 2>&1)"; RC=$?
ok  "good manifest + key present is SAFE (rc 0)" test "${RC}" -eq 0
has "good manifest prints OVERALL: SAFE-TO-RESTORE" "${OUT}" "OVERALL: SAFE-TO-RESTORE"
has "good manifest reports both artifacts checksum OK" "${OUT}" "checksum OK"
no  "good manifest prints no WARN line" bash -c 'printf "%s" "$1" | grep -q "^WARN:"' _ "${OUT}"
no  "good manifest prints no PROBLEM line" bash -c 'printf "%s" "$1" | grep -q "^PROBLEM:"' _ "${OUT}"

# (b) A tampered checksum (artifact bytes changed after the manifest) -> NOT-SAFE.
printf 'tampered-extra-bytes\n' >> "${RD}/pg.postgres.sql.gz.age"
OUT="$(bk_plan_restore "${RD}" present 2>&1)"; RC=$?
no  "tampered artifact is NOT safe (rc != 0)" test "${RC}" -eq 0
has "tampered artifact prints OVERALL: NOT-SAFE" "${OUT}" "OVERALL: NOT-SAFE"
has "tampered artifact names a size/checksum problem" "${OUT}" "pg.postgres.sql.gz.age"
rm -rf "${PD}"

# (c) A short/malformed checksum string in the manifest -> NOT-SAFE.
PD="$(mktemp -d)"; RD="${PD}/run"; mkrun "${RD}" 1
sed -i -E 's#^(pg\|postgres\|[^|]*\|ok\|[0-9]+\|).*#\1deadbeef#' "${RD}/manifest.txt"   # truncate the sha
OUT="$(bk_plan_restore "${RD}" present 2>&1)"; RC=$?
no  "short checksum is NOT safe (rc != 0)" test "${RC}" -eq 0
has "short checksum prints OVERALL: NOT-SAFE" "${OUT}" "OVERALL: NOT-SAFE"
has "short checksum problem is explained" "${OUT}" "integrity cannot be verified"
rm -rf "${PD}"

# (d) Missing key -> NOT-SAFE WITH a clear, actionable hint.
PD="$(mktemp -d)"; RD="${PD}/run"; mkrun "${RD}" 1
OUT="$(bk_plan_restore "${RD}" missing 2>&1)"; RC=$?
no  "missing key is NOT safe (rc != 0)" test "${RC}" -eq 0
has "missing key prints OVERALL: NOT-SAFE" "${OUT}" "OVERALL: NOT-SAFE"
has "missing key gives the offline-copy hint" "${OUT}" "offline copy of the age key"
rm -rf "${PD}"

# (e) A NEWER/unknown manifest schema -> a WARN (but, integrity intact, still SAFE).
PD="$(mktemp -d)"; RD="${PD}/run"; mkrun "${RD}" 99
OUT="$(bk_plan_restore "${RD}" present 2>&1)"; RC=$?
has "unknown schema emits a WARN line" "${OUT}" "WARN:"
has "unknown schema WARN names the schema mismatch" "${OUT}" "NEWER than supported"
ok  "unknown schema with intact integrity is still SAFE (rc 0)" test "${RC}" -eq 0
rm -rf "${PD}"

# (f) A decrypt probe that the caller marks FAILED -> NOT-SAFE (wrong key).
PD="$(mktemp -d)"; RD="${PD}/run"; mkrun "${RD}" 1
OUT="$(bk_plan_restore "${RD}" present failed 2>&1)"; RC=$?
no  "failed decrypt probe is NOT safe (rc != 0)" test "${RC}" -eq 0
has "failed decrypt probe prints OVERALL: NOT-SAFE" "${OUT}" "OVERALL: NOT-SAFE"
has "failed decrypt probe is explained" "${OUT}" "decrypt check FAILED"
rm -rf "${PD}"

# (g) A run dir with NO manifest -> NOT-SAFE (cannot validate).
PD="$(mktemp -d)"; mkdir -p "${PD}/empty"
OUT="$(bk_plan_restore "${PD}/empty" present 2>&1)"; RC=$?
no  "no-manifest run is NOT safe (rc != 0)" test "${RC}" -eq 0
has "no-manifest run prints OVERALL: NOT-SAFE" "${OUT}" "OVERALL: NOT-SAFE"
rm -rf "${PD}"

# ===========================================================================
section "PLAN — restore --dry-run is wired, plan-only, and refuses a real restore"
# ---------------------------------------------------------------------------
fhas "backup.sh dispatches the restore subcommand" "${BACKUP}" "restore)  cmd_restore"
fhas "restore is plan-only (no live data / container)" "${BACKUP}" "PLAN-ONLY restore validation"

D="$(mkproj)"; RUN="${D}/data/backups/daily/20260526-000000"; mkrun "${RUN}" 1
# No age key in the throwaway project -> NOT-SAFE on the key alone.
OUT="$(cd "${D}" && bash scripts/backup.sh restore --dry-run "${RUN}" 2>&1)"; RC=$?
no  "dry-run without a key is NOT safe (rc != 0)" test "${RC}" -eq 0
has "dry-run without a key prints NOT-SAFE" "${OUT}" "OVERALL: NOT-SAFE"
# Now provide a (dummy, non-empty) key file -> the integrity-clean run becomes SAFE.
mkdir -p "${D}/secrets/backup"; printf 'AGE-SECRET-KEY-1DUMMY\n' > "${D}/secrets/backup/age-identity.key"
OUT="$(cd "${D}" && bash scripts/backup.sh restore --dry-run "${RUN}" 2>&1)"; RC=$?
ok  "dry-run with a key + clean integrity is SAFE (rc 0)" test "${RC}" -eq 0
has "dry-run with a key prints SAFE-TO-RESTORE" "${OUT}" "OVERALL: SAFE-TO-RESTORE"
has "dry-run points at the guarded real restore" "${OUT}" "scripts/restore.sh"
# Without --dry-run, restore REFUSES (never performs a real restore here).
OUT="$(cd "${D}" && bash scripts/backup.sh restore "${RUN}" 2>&1)"; RC=$?
no  "restore WITHOUT --dry-run is refused (rc != 0)" test "${RC}" -eq 0
has "refusal points to the guarded scripts/restore.sh" "${OUT}" "scripts/restore.sh"
rm -rf "${D}" 2>/dev/null || true

# ===========================================================================
section "VERIFY — drill skips gracefully off-Pi + asserts post-restore HEALTH"
# ---------------------------------------------------------------------------
# Off a Pi (no Docker) the drill must SKIP cleanly (exit 0), never fail the matrix.
fhas "verify has an off-Pi (no Docker CLI) skip branch"   "${VERIFY}" "SKIP: run this ON the Raspberry Pi"
fhas "verify also skips when the daemon is unreachable"   "${VERIFY}" "docker info"
# Each restored store gets an explicit, trivial HEALTH read (usable, not just unpacked).
fhas "pg/mysql health read is SELECT 1"                   "${VERIFY}" "SELECT 1;"
fhas "mongo health read is an admin ping"                 "${VERIFY}" "adminCommand({ping:1})"
fhas "redis health read is PING"                          "${VERIFY}" "redis-cli ping"
fhas "config health read is file presence"                "${VERIFY}" "file presence ok"
fhas "a failed health read fails the drill"               "${VERIFY}" "post-restore health read"
fhas "verify READS the manifest (checksum pre-check)"     "${VERIFY}" "Manifest integrity pre-check"

# Behavioral: with no Docker present here, the drill itself must exit 0 + say SKIP.
if ! command -v docker >/dev/null 2>&1; then
  OUT="$(bash "${VERIFY}" 2>&1)"; RC=$?
  ok  "verify exits 0 off-Pi (no Docker)" test "${RC}" -eq 0
  has "verify prints a clear SKIP off-Pi" "${OUT}" "SKIP"
else
  tests_skipped=$((tests_skipped+1)); printf '  %s•%s verify off-Pi behavior (Docker present — drill is live; skipped here)\n' "${Y}" "${O}"
fi

# ===========================================================================
section "NOTIFY — failures surface through the notifier seam (injected, no real send)"
# ---------------------------------------------------------------------------
tests_run=$((tests_run+1))
if declare -F bk_notify_failure >/dev/null 2>&1; then _pass "backup-lib.sh provides bk_notify_failure"
else _fail "bk_notify_failure missing"; fi

ND="$(mktemp -d)"; STUB="${ND}/stub.sh"; MARK="${ND}/got"
# An injected stub notifier that just RECORDS what it was handed (no network).
cat > "${STUB}" <<'EOF'
#!/usr/bin/env bash
printf 'LABEL=%s\n' "$1" > "${MARK_FILE}"
printf 'BODY:' >> "${MARK_FILE}"; cat >> "${MARK_FILE}"
EOF
export MARK_FILE="${MARK}"

# (a) The seam is invoked with the right LABEL on argv and BODY on stdin.
bk_notify_failure "${STUB}" "backup-failed" "run exit 1 - see backup.log"; RC=$?
ok   "notify returns 0 (best-effort) on a real send" test "${RC}" -eq 0
fhas "seam received the LABEL on argv" "${MARK}" "LABEL=backup-failed"
fhas "seam received the BODY on stdin" "${MARK}" "run exit 1 - see backup.log"

# (b) An empty command is a clean no-op — nothing is sent.
rm -f "${MARK}"
bk_notify_failure "" "x" "y"; RC=$?
ok "empty notifier command returns 0" test "${RC}" -eq 0
no "empty notifier command sends nothing" test -f "${MARK}"

# (c) "off" disables the seam entirely.
rm -f "${MARK}"
bk_notify_failure "off" "x" "y"; RC=$?
ok "'off' notifier returns 0" test "${RC}" -eq 0
no "'off' notifier sends nothing" test -f "${MARK}"

# (d) A notifier that FAILS must not fail the backup (best-effort contract).
printf '#!/usr/bin/env bash\nexit 1\n' > "${ND}/fail.sh"
bk_notify_failure "${ND}/fail.sh" "x" "y"; RC=$?
ok "a failing notifier still returns 0" test "${RC}" -eq 0

# (e) A missing notifier path is a clean no-op.
bk_notify_failure "/no/such/notifier" "x" "y"; RC=$?
ok "a missing notifier path returns 0" test "${RC}" -eq 0
unset MARK_FILE; rm -rf "${ND}"

# Wiring: backup.sh surfaces BOTH a failed backup and a failed offsite, gated by .env.
fhas "backup.sh resolves BACKUP_NOTIFY_CMD"           "${BACKUP}" "BACKUP_NOTIFY_CMD"
fhas "the default notifier is the telegram seam"      "${BACKUP}" "notify-telegram.sh"
fhas "cmd_now surfaces a FAILED backup"               "${BACKUP}" 'notify_backup_failure "backup-failed"'
fhas "cmd_now surfaces a FAILED offsite push"         "${BACKUP}" 'notify_backup_failure "offsite-failed"'
fhas ".env.example documents BACKUP_NOTIFY_CMD"       "${PROJECT_ROOT}/.env.example" "BACKUP_NOTIFY_CMD="

# ===========================================================================
section "Results"
# ---------------------------------------------------------------------------
printf '  %d run, %s%d failed%s, %d skipped\n' \
  "${tests_run}" "$( ((tests_failed)) && echo "${R}" || echo "${G}")" "${tests_failed}" "${O}" "${tests_skipped}"
if (( tests_failed > 0 )); then
  printf '%sTESTS FAILED%s\n' "${R}" "${O}" >&2
  exit 1
fi
printf '%sALL TESTS PASSED%s\n' "${G}" "${O}"
exit 0
