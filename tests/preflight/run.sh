#!/usr/bin/env bash
# ===========================================================================
# pi-system — preflight TEST HARNESS
# ---------------------------------------------------------------------------
# Exercises the PURE decision logic of scripts/preflight.sh (via the sourced
# library scripts/lib/preflight-lib.sh) against FIXTURES and MOCKED command
# outputs, so its PASS/WARN/FAIL decisions are verified WITHOUT a live
# Docker/Pi — mirroring how every prior part of this platform was checked.
#
# Coverage (each maps to a likely first-run failure):
#   * missing .env                  -> pf_missing_required on an absent file
#   * missing/empty required var    -> pf_missing_required on a partial .env
#   * weak secret (pure mapping)    -> pf_classify_secret_audit on mocked output
#   * weak secret (REAL, no docker) -> the actual scripts/check-secrets.sh
#   * bad compose (collisions)      -> pure host-port / container-name detectors
#   * bad compose (parse, OPTIONAL) -> real `docker compose config`, docker-gated
#   * tag-missing simulation        -> pf_check_image with a mocked registry seam
#   * no-arm64 image                -> pf_check_image / pf_manifest_arm64
#   * offline registry             -> pf_check_image (must WARN, never FAIL)
#   * low-disk / low-RAM            -> pf_classify_min + mocked df/meminfo seams
#   * arch / boot-media verdicts    -> pf_arch_verdict / pf_sdcard_verdict
#   * registry vs real repo         -> every referenced compose file exists
#
# A handful of checks (the REAL check-secrets run, the real-repo integrity
# checks, the docker-gated parse) also run for real here, so this harness is
# both an offline unit suite AND a couple of live checks.
#
# Usage:   ./tests/preflight/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${PROJECT_ROOT}/scripts/lib/preflight-lib.sh"
CHECK_SECRETS="${PROJECT_ROOT}/scripts/check-secrets.sh"
FIX="${SCRIPT_DIR}/fixtures"

if [[ ! -f "${LIB}" ]]; then
  printf 'FATAL: library not found: %s\n' "${LIB}" >&2
  exit 2
fi
# shellcheck source=../../scripts/lib/preflight-lib.sh
source "${LIB}"

# --- Colours (off when not a TTY) ------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; O=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; O=''
fi

# --- Tiny assertion framework ----------------------------------------------
tests_run=0; tests_failed=0; tests_skipped=0
_pass() { printf '  %s✓%s %s\n' "${G}" "${O}" "$1"; }
_fail() { printf '  %s✗%s %s\n' "${R}" "${O}" "$1"; tests_failed=$((tests_failed+1)); }
_skip() { printf '  %s~%s %s (skipped)\n' "${Y}" "${O}" "$1"; tests_skipped=$((tests_skipped+1)); }
section() { printf '\n%s== %s ==%s\n' "${C}" "$1" "${O}"; }

# check NAME ACTUAL EXPECTED
check() {
  tests_run=$((tests_run+1))
  if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1 — expected [$3], got [$2]"; fi
}
# check_contains NAME HAYSTACK NEEDLE
check_contains() {
  tests_run=$((tests_run+1))
  if [[ "$2" == *"$3"* ]]; then _pass "$1"; else _fail "$1 — [$2] does not contain [$3]"; fi
}
# check_rc NAME ACTUAL_RC EXPECTED_RELATION(zero|nonzero)
check_rc() {
  tests_run=$((tests_run+1))
  case "$3" in
    zero)    [[ "$2" == "0" ]] && _pass "$1" || _fail "$1 — expected rc 0, got $2" ;;
    nonzero) [[ "$2" != "0" ]] && _pass "$1" || _fail "$1 — expected non-zero rc, got $2" ;;
  esac
}

# Fake (but non-secret-shaped) strong/weak .env writers — generated at RUNTIME
# so no secret-bearing file is ever committed to the repo.
STRONG_VAL="PreflightFixtureStrongSecretValue0000000000"   # 43 chars, alnum
FAKE_RECIPIENT="age1fixtureonlyxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
write_strong_env() {
  local f="$1" k
  : > "${f}"
  for k in POSTGRES_PASSWORD MYSQL_ROOT_PASSWORD MYSQL_PASSWORD \
           MONGO_INITDB_ROOT_PASSWORD REDIS_PASSWORD PGADMIN_DEFAULT_PASSWORD \
           ME_CONFIG_BASICAUTH_PASSWORD KC_DB_PASSWORD KC_BOOTSTRAP_ADMIN_PASSWORD \
           N8N_DB_PASSWORD N8N_ENCRYPTION_KEY; do
    printf '%s=%s\n' "${k}" "${STRONG_VAL}" >> "${f}"
  done
  printf 'BACKUP_AGE_RECIPIENTS=%s\n' "${FAKE_RECIPIENT}" >> "${f}"
}
write_weak_env() {
  local f="$1"
  {
    printf 'REDIS_PASSWORD=password\n'                         # weak -> CRITICAL
    printf 'N8N_ENCRYPTION_KEY=%s\n' "${STRONG_VAL}"
    printf 'BACKUP_AGE_RECIPIENTS=%s\n' "${FAKE_RECIPIENT}"
  } > "${f}"
}
# Run the REAL check-secrets.sh against a given .env in a throwaway project dir.
# Sets the GLOBALS CS_OUT (combined output) and CS_RC (exit code). Must be
# called directly (NOT via $()), or the globals would be lost to a subshell.
run_check_secrets_on() {
  local envfile="$1" tmp
  tmp="$(mktemp -d)"
  mkdir -p "${tmp}/scripts"
  cp "${CHECK_SECRETS}" "${tmp}/scripts/check-secrets.sh"
  cp "${envfile}" "${tmp}/.env"
  CS_OUT="$(cd "${tmp}" && bash "${tmp}/scripts/check-secrets.sh" 2>&1)"
  CS_RC=$?
  rm -rf "${tmp}"
}

# ===========================================================================
section "ENV — presence & value extraction (pure)"
# ---------------------------------------------------------------------------

# missing .env: everything required is reported missing.
mapfile -t M < <(pf_missing_required "/no/such/dir/.env" ALPHA BETA GAMMA)
check "missing .env -> all required reported" "${M[*]}" "ALPHA BETA GAMMA"

# partial .env: only the empty + absent vars are reported.
mapfile -t M < <(pf_missing_required "${FIX}/env-partial.env" \
  PRESENT_ONE PRESENT_QUOTED EMPTY_VAR EMPTY_QUOTED MISSING_VAR)
check "missing required var -> exactly empty+absent" "${M[*]}" "EMPTY_VAR EMPTY_QUOTED MISSING_VAR"

# value extraction never sources, strips quotes / edge ws.
check "value: plain"        "$(pf_env_value PRESENT_ONE    "${FIX}/env-partial.env")" "hello"
check "value: dquote strip" "$(pf_env_value PRESENT_QUOTED "${FIX}/env-partial.env")" "quoted value"
check "value: squote strip" "$(pf_env_value PRESENT_SINGLE "${FIX}/env-partial.env")" "single quoted"
check "value: empty"        "$(pf_env_value EMPTY_VAR      "${FIX}/env-partial.env")" ""
check "value: absent"       "$(pf_env_value MISSING_VAR    "${FIX}/env-partial.env")" ""

# CRLF handling (generated at runtime so a CR byte actually survives).
TMP_CRLF="$(mktemp)"; printf 'CR_VAR=value\r\n' > "${TMP_CRLF}"
check "value: CRLF trimmed" "$(pf_env_value CR_VAR "${TMP_CRLF}")" "value"
rm -f "${TMP_CRLF}"

# pf_env_has distinguishes "present but empty" from "absent".
tests_run=$((tests_run+1)); pf_env_has EMPTY_VAR  "${FIX}/env-partial.env" && _pass "has: present-but-empty is present" || _fail "has: EMPTY_VAR should be present"
tests_run=$((tests_run+1)); pf_env_has MISSING_VAR "${FIX}/env-partial.env" && _fail "has: MISSING_VAR should be absent" || _pass "has: absent var is absent"

# ===========================================================================
section "SECRETS — strength via reused check-secrets.sh"
# ---------------------------------------------------------------------------

# Pure mapping of a check-secrets run to a preflight verdict (mocked outputs).
check "audit map: rc!=0 -> FAIL" "$(pf_classify_secret_audit 1 'x ✗ REDIS_PASSWORD weak')" "FAIL"
check "audit map: warn  -> WARN" "$(pf_classify_secret_audit 0 '  ! KC_DB_PASSWORD: short')" "WARN"
check "audit map: clean -> PASS" "$(pf_classify_secret_audit 0 '  ✓ all set')" "PASS"

# REAL reuse: the actual auditor must flag a weak secret (critical => non-zero).
if [[ -f "${CHECK_SECRETS}" ]]; then
  CS_OUT=""; CS_RC=0
  TMP_ENV="$(mktemp)"; write_weak_env "${TMP_ENV}"
  run_check_secrets_on "${TMP_ENV}"
  check_rc "weak secret -> check-secrets exits non-zero (real)" "${CS_RC}" "nonzero"
  check_contains "weak secret -> reported as weak (real)" "${CS_OUT}" "weak"
  rm -f "${TMP_ENV}"

  # And a strong .env passes cleanly (real).
  CS_OUT=""; CS_RC=0
  TMP_ENV="$(mktemp)"; write_strong_env "${TMP_ENV}"
  run_check_secrets_on "${TMP_ENV}"
  check_rc "strong secrets -> check-secrets exits zero (real)" "${CS_RC}" "zero"
  rm -f "${TMP_ENV}"
else
  _skip "real check-secrets.sh tests (script not found)"
fi

# CROSS-CHECK: generate-secrets.sh fills EXACTLY the secret keys check-secrets.sh
# audits. If they drift, `generate-secrets` then `check-secrets` would fail on a fresh
# install (e.g. a missing N8N_ENCRYPTION_KEY is CRITICAL). Extract both SECRET_KEYS
# array literals (without sourcing the scripts) and compare as sorted sets.
GEN_SECRETS="${PROJECT_ROOT}/scripts/generate-secrets.sh"
extract_secret_keys() {
  awk '/^SECRET_KEYS=\(/{f=1;next} f&&/^\)/{f=0} f{gsub(/[ \t]/,"");print}' "$1" \
    | grep -E '^[A-Z0-9_]+$' | sort -u | paste -sd, -
}
if [[ -f "${GEN_SECRETS}" && -f "${CHECK_SECRETS}" ]]; then
  gen_keys="$(extract_secret_keys "${GEN_SECRETS}")"
  chk_keys="$(extract_secret_keys "${CHECK_SECRETS}")"
  tests_run=$((tests_run+1))
  if [[ -n "${gen_keys}" && "${gen_keys}" == "${chk_keys}" ]]; then
    _pass "SECRET_KEYS in sync: generate-secrets == check-secrets (${gen_keys})"
  else
    _fail "SECRET_KEYS DRIFT — generate=[${gen_keys}] check=[${chk_keys}]"
  fi
else
  _skip "secret-key cross-check (a script is missing)"
fi

# ===========================================================================
section "HOST — arch, disk, RAM (pure + mocked seams)"
# ---------------------------------------------------------------------------
check "arch: aarch64 -> PASS" "$(pf_arch_verdict aarch64)" "PASS"
check "arch: arm64   -> PASS" "$(pf_arch_verdict arm64)"   "PASS"
check "arch: x86_64  -> WARN" "$(pf_arch_verdict x86_64)"  "WARN"

# Numeric "more is better" classifier boundaries (warn_at=10, fail_at=2).
check "disk: 12 -> PASS"   "$(pf_classify_min 12 10 2)" "PASS"
check "disk: 10 -> PASS"   "$(pf_classify_min 10 10 2)" "PASS"
check "disk: 9  -> WARN"   "$(pf_classify_min 9 10 2)"  "WARN"
check "disk: 2  -> WARN"   "$(pf_classify_min 2 10 2)"  "WARN"
check "disk: 1  -> FAIL"   "$(pf_classify_min 1 10 2)"  "FAIL"
check "disk: bad -> WARN"  "$(pf_classify_min xx 10 2)" "WARN"

# low-disk SIMULATION via the mockable seam (1 GB free, threshold 10/2 GB).
LOWDISK="$(
  pf_disk_avail_kb() { echo $((1*1024*1024)); }     # 1 GiB in KiB
  pf_classify_min "$(pf_disk_avail_kb /x)" $((10*1024*1024)) $((2*1024*1024))
)"
check "low-disk seam (1GB) -> FAIL" "${LOWDISK}" "FAIL"

# low-RAM SIMULATION via the mockable seam (1500 MB total, threshold 3500/1500).
LOWRAM="$(
  pf_mem_total_mb() { echo 1400; }
  pf_classify_min "$(pf_mem_total_mb)" 3500 1500
)"
check "low-RAM seam (1400MB) -> FAIL" "${LOWRAM}" "FAIL"
OKRAM="$(
  pf_mem_total_mb() { echo 3800; }                  # a 4 GB Pi
  pf_classify_min "$(pf_mem_total_mb)" 3500 1500
)"
check "ok-RAM seam (3800MB) -> PASS" "${OKRAM}" "PASS"

# ===========================================================================
section "BOOT MEDIA — SSD vs SD card (pure)"
# ---------------------------------------------------------------------------
check "boot: mmcblk -> WARN (SD)"   "$(pf_sdcard_verdict /dev/mmcblk0p2)"  "WARN"
check "boot: nvme   -> PASS (SSD)"  "$(pf_sdcard_verdict /dev/nvme0n1p2)"  "PASS"
check "boot: sda    -> PASS"        "$(pf_sdcard_verdict /dev/sda2)"       "PASS"
check "boot: unknown-> UNKNOWN"     "$(pf_sdcard_verdict overlay)"         "UNKNOWN"

# ===========================================================================
section "COMPOSE — image / port / name / volume parsing & collisions (pure)"
# ---------------------------------------------------------------------------
# image extraction: literal kept, commented + interpolated(local-build) skipped.
mapfile -t IMG < <(pf_extract_images "${FIX}/compose-good.yml")
check "images: only the literal upstream tag" "${IMG[*]}" "nginx:1.27.3-alpine"

# host ports: proto-aware; 443 tcp + 443 udp are NOT a collision.
mapfile -t HP < <(pf_extract_host_ports "${FIX}/compose-good.yml")
check "ports: proto-aware, commented ignored" "${HP[*]}" "80/tcp 443/tcp 443/udp"
mapfile -t DUP < <(pf_extract_host_ports "${FIX}/compose-good.yml" | pf_find_duplicates)
check "ports: clean file has NO collisions" "${DUP[*]}" ""

# the broken fixture must surface BOTH a port and a name collision.
mapfile -t DUP < <(pf_extract_host_ports "${FIX}/compose-collision.yml" | pf_find_duplicates)
check "ports: collision fixture flags 9000/tcp" "${DUP[*]}" "9000/tcp"
mapfile -t DUP < <(pf_extract_container_names "${FIX}/compose-collision.yml" | pf_find_duplicates)
check "names: collision fixture flags dup_name" "${DUP[*]}" "dup_name"

# volume extraction.
mapfile -t VOL < <(pf_extract_volumes "${FIX}/compose-good.yml")
check "volumes: both named volumes extracted" "${VOL[*]}" "web_data web_cache"

# OPTIONAL real parse check (genuinely needs the Compose engine).
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  if docker compose -f "${FIX}/compose-invalid.yml" config >/dev/null 2>&1; then
    tests_run=$((tests_run+1)); _fail "bad compose: docker compose config should REJECT compose-invalid.yml"
  else
    tests_run=$((tests_run+1)); _pass "bad compose: docker compose config rejects compose-invalid.yml (real)"
  fi
else
  _skip "bad compose real parse (docker compose unavailable)"
fi

# ===========================================================================
section "IMAGES — registry existence & arm64 (pure + mocked seam)"
# ---------------------------------------------------------------------------
# manifest arm64 parse against committed fixtures.
tests_run=$((tests_run+1)); pf_manifest_arm64 "$(cat "${FIX}/manifest-arm64.json")"     && _pass "manifest: multi-arch advertises arm64" || _fail "manifest: arm64 list should pass"
tests_run=$((tests_run+1)); pf_manifest_arm64 "$(cat "${FIX}/manifest-amd64only.json")" && _fail "manifest: amd64-only must NOT pass" || _pass "manifest: amd64-only correctly rejected"

# manifest-error classifier.
check "err: missing tag -> MISSING" "$(pf_classify_manifest_error 'no such manifest: docker.io/library/x:bad')" "MISSING"
check "err: dns fail    -> OFFLINE" "$(pf_classify_manifest_error 'dial tcp: lookup registry-1.docker.io: no such host')" "OFFLINE"
check "err: experimental-> UNKNOWN" "$(pf_classify_manifest_error 'only supported with experimental cli features enabled')" "UNKNOWN"

# pf_check_image end-to-end with a MOCKED registry seam (the tag-missing sim).
V="$( pf_manifest_inspect() { cat "${FIX}/manifest-arm64.json"; return 0; }; pf_check_image foo:1 )"
check "image: arm64 present -> PASS" "${V%%|*}" "PASS"
V="$( pf_manifest_inspect() { cat "${FIX}/manifest-amd64only.json"; return 0; }; pf_check_image foo:1 )"
check "image: no arm64      -> FAIL" "${V%%|*}" "FAIL"
V="$( pf_manifest_inspect() { echo 'no such manifest: docker.io/library/foo:1' >&2; return 1; }; pf_check_image foo:1 )"
check "image: tag missing   -> FAIL" "${V%%|*}" "FAIL"
V="$( pf_manifest_inspect() { echo 'dial tcp: lookup registry: no such host' >&2; return 1; }; pf_check_image foo:1 )"
check "image: offline       -> WARN (never FAIL)" "${V%%|*}" "WARN"

# ===========================================================================
section "DOCKER LOGGING — rotation caps (pure classifier + daemon.json seam)"
# ---------------------------------------------------------------------------
# Pure classifier: 'local' rotates by default; json-file needs BOTH caps; a
# missing cap (or unknown/other driver) is a WARN, never a FAIL.
V="$(pf_logrotate_verdict json-file 10m 3)";  check "logrot: json-file + both caps -> PASS" "${V%%|*}" "PASS"
V="$(pf_logrotate_verdict json-file '' '')";  check "logrot: json-file + NO caps  -> WARN" "${V%%|*}" "WARN"
V="$(pf_logrotate_verdict json-file 10m '')"; check "logrot: json-file + half caps -> WARN" "${V%%|*}" "WARN"
V="$(pf_logrotate_verdict local '' '')";      check "logrot: 'local' driver       -> PASS" "${V%%|*}" "PASS"
V="$(pf_logrotate_verdict '' '' '')";         check "logrot: unknown driver       -> WARN" "${V%%|*}" "WARN"
V="$(pf_logrotate_verdict journald '' '')";   check "logrot: other driver         -> WARN" "${V%%|*}" "WARN"
# The caps-missing WARN must explain itself + point at the example file.
V="$(pf_logrotate_verdict json-file '' '')"
check_contains "logrot: caps-missing WARN names the fix" "${V#*|}" "docker-daemon.json.example"
# CRITICAL invariant: this check is ADVISORY — it must NEVER return FAIL.
nf=0
for d in json-file local "" overlay2 journald; do
  for ms in "" 10m; do for mf in "" 3; do
    [[ "$(pf_logrotate_verdict "$d" "$ms" "$mf")" == FAIL\|* ]] && nf=1
  done; done
done
check "logrot: NEVER returns FAIL (advisory only)" "${nf}" "0"

# daemon.json log-opt seam (no jq): reads caps from the REAL example, returns ''
# when the file or the key is absent.
EXAMPLE_DAEMON="${PROJECT_ROOT}/infrastructure/docker-daemon.json.example"
check "daemon opt: max-size from example" "$(pf_daemon_log_opt "${EXAMPLE_DAEMON}" max-size)" "10m"
check "daemon opt: max-file from example" "$(pf_daemon_log_opt "${EXAMPLE_DAEMON}" max-file)" "3"
check "daemon opt: absent file -> empty"  "$(pf_daemon_log_opt /no/such/daemon.json max-size)" ""
check "daemon opt: absent key  -> empty"  "$(pf_daemon_log_opt "${FIX}/daemon-nocaps.json" max-size)" ""

# End-to-end (mirrors the orchestrator): mocked effective driver + real opts.
APPLIED="$(
  pf_docker_log_driver() { echo json-file; }
  ms="$(pf_daemon_log_opt "${EXAMPLE_DAEMON}" max-size)"
  mf="$(pf_daemon_log_opt "${EXAMPLE_DAEMON}" max-file)"
  pf_logrotate_verdict "$(pf_docker_log_driver)" "${ms}" "${mf}"
)"
check "logrot wired: example caps applied -> PASS" "${APPLIED%%|*}" "PASS"
NOTAPPLIED="$(
  pf_docker_log_driver() { echo json-file; }
  ms="$(pf_daemon_log_opt "${FIX}/daemon-nocaps.json" max-size)"
  mf="$(pf_daemon_log_opt "${FIX}/daemon-nocaps.json" max-file)"
  pf_logrotate_verdict "$(pf_docker_log_driver)" "${ms}" "${mf}"
)"
check "logrot wired: caps NOT applied -> WARN (never FAIL)" "${NOTAPPLIED%%|*}" "WARN"

# The check is WIRED into preflight.sh and degrades gracefully without Docker.
PF="${PROJECT_ROOT}/scripts/preflight.sh"
tests_run=$((tests_run+1)); grep -q 'pf_logrotate_verdict' "${PF}" \
  && _pass "preflight wires the log-rotation check (calls pf_logrotate_verdict)" \
  || _fail "preflight.sh does not call pf_logrotate_verdict"
tests_run=$((tests_run+1)); grep -q '{{.LoggingDriver}}' "${LIB}" \
  && _pass "log-rotation check reads the driver via 'docker info {{.LoggingDriver}}'" \
  || _fail "pf_docker_log_driver should query 'docker info --format {{.LoggingDriver}}'"
tests_run=$((tests_run+1)); grep -q 'Skipped Docker log-rotation' "${PF}" \
  && _pass "log-rotation check skips gracefully when Docker is absent" \
  || _fail "preflight.sh lacks a graceful skip for the log-rotation check"

# ===========================================================================
section "REGISTRY — component map vs the REAL repo (integrity)"
# ---------------------------------------------------------------------------
# Every compose file referenced by the registry actually exists.
missing=0
for comp in "${PF_ALL_COMPONENTS[@]}"; do
  for f in ${PF_COMPOSE[${comp}]}; do
    [[ -f "${PROJECT_ROOT}/${f}" ]] || { _fail "registry: ${comp} references missing file ${f}"; missing=1; tests_run=$((tests_run+1)); }
  done
done
tests_run=$((tests_run+1)); (( missing == 0 )) && _pass "registry: all referenced compose files exist"

# Every component with required vars / a profile is a known component.
badkey=0
for comp in "${!PF_REQVARS[@]}" "${!PF_PROFILE[@]}"; do
  pf_is_component "${comp}" || { _fail "registry: '${comp}' is not a known component"; badkey=1; tests_run=$((tests_run+1)); }
done
tests_run=$((tests_run+1)); (( badkey == 0 )) && _pass "registry: all keyed components are known"

# container -> component mapping sanity.
check "map: caddy -> proxy"          "$(pf_container_to_component caddy)"        "proxy"
check "map: n8n-db -> automation"    "$(pf_container_to_component n8n-db)"       "automation"
check "map: nuget_cache -> cache"    "$(pf_container_to_component nuget_cache)"  "cache"
check "map: unknown -> (empty)"      "$(pf_container_to_component something)"    ""

# The REAL platform compose files must have no host-port/name collisions.
REAL_FILES=(
  infrastructure/docker-compose.yml infrastructure/management.compose.yml
  services/proxy/proxy.compose.yml services/databases/databases.compose.yml
  services/db-admin/db-admin.compose.yml services/auth/auth.compose.yml
  services/automation/automation.compose.yml services/dashboard/dashboard.compose.yml
  services/cache/cache.compose.yml services/backup/backup.compose.yml
)
mapfile -t DUP < <( for f in "${REAL_FILES[@]}"; do pf_extract_host_ports "${PROJECT_ROOT}/${f}"; done | pf_find_duplicates )
check "real repo: no host-port collisions" "${DUP[*]}" ""
mapfile -t DUP < <( for f in "${REAL_FILES[@]}"; do pf_extract_container_names "${PROJECT_ROOT}/${f}"; done | pf_find_duplicates )
check "real repo: no container-name collisions" "${DUP[*]}" ""

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
