#!/usr/bin/env bash
# ===========================================================================
# pi-system — host HEALTH-MONITOR TEST HARNESS
# ---------------------------------------------------------------------------
# Exercises the PURE decision logic of scripts/health-monitor.sh (via the
# sourced library scripts/lib/health-monitor-lib.sh) against FIXTURES and MOCKED
# seams, so its parsing and PASS/WARN/FAIL/SKIP verdicts are verified WITHOUT a
# real Pi, Docker, or root — mirroring tests/mem-budget/run.sh and
# tests/preflight/run.sh.
#
# Coverage (each maps to a real way the monitor could be wrong):
#   * threshold classification     -> hm_classify_high (temp/disk band edges)
#   * sensor parsing               -> vcgencmd / thermal-zone fixtures -> °C
#   * throttle-flag decoding       -> 0x0 PASS / past WARN / now FAIL / junk SKIP
#   * df parsing                   -> capacity %, available KB from df fixtures
#   * disk "main consumer"         -> hm_largest (backups vs docker)
#   * free parsing + mem/swap math -> hm_free_field + hm_classify_mem/_swap
#   * docker stats size parsing    -> hm_size_to_mib (MiB/GiB/KiB/MB, floats)
#   * "near its limit" detection   -> hm_containers_verdict / _near_limit
#   * verdict folding (incl. SKIP) -> hm_worst / hm_severity
#   * NOTIFIER decision            -> hm_should_notify (only WARN/FAIL) / kuma map
#   * end-to-end via mocked seams  -> healthy=PASS(silent) / warn / fail(notify)
#   * the REAL scripts             -> syntax-check + installed cron line shape
#
# Usage:   ./tests/health-monitor/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${PROJECT_ROOT}/scripts/lib/health-monitor-lib.sh"
ENTRY="${PROJECT_ROOT}/scripts/health-monitor.sh"
CRON="${PROJECT_ROOT}/scripts/health-monitor-install-cron.sh"
FIX="${SCRIPT_DIR}/fixtures"

if [[ ! -f "${LIB}" ]]; then
  printf 'FATAL: library not found: %s\n' "${LIB}" >&2
  exit 2
fi
# shellcheck source=../../scripts/lib/health-monitor-lib.sh
source "${LIB}"

# --- Colours (off when not a TTY) ------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; O=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; O=''
fi

# --- Tiny assertion framework (same shape as tests/mem-budget/run.sh) ------
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
# check_rc NAME ACTUAL_RC zero|nonzero
check_rc() {
  tests_run=$((tests_run+1))
  case "$3" in
    zero)    [[ "$2" == "0" ]] && _pass "$1" || _fail "$1 — expected rc 0, got $2" ;;
    nonzero) [[ "$2" != "0" ]] && _pass "$1" || _fail "$1 — expected non-zero rc, got $2" ;;
  esac
}
# contains NAME HAYSTACK NEEDLE
contains() {
  tests_run=$((tests_run+1))
  if [[ "$2" == *"$3"* ]]; then _pass "$1"; else _fail "$1 — [$2] does not contain [$3]"; fi
}

# ===========================================================================
section "CLASSIFY — 'more is worse' bands (temp / disk / generic)"
# ---------------------------------------------------------------------------
check "high: 47 (warn 70 fail 80) -> PASS"  "$(hm_classify_high 47 70 80)" "PASS"
check "high: 69 -> PASS (below warn)"        "$(hm_classify_high 69 70 80)" "PASS"
check "high: 70 -> WARN (== warn)"           "$(hm_classify_high 70 70 80)" "WARN"
check "high: 79 -> WARN"                      "$(hm_classify_high 79 70 80)" "WARN"
check "high: 80 -> FAIL (== fail)"           "$(hm_classify_high 80 70 80)" "FAIL"
check "high: 95 -> FAIL"                      "$(hm_classify_high 95 70 80)" "FAIL"
check "high: non-numeric -> WARN (soft)"     "$(hm_classify_high abc 70 80)" "WARN"
# disk band (warn 80 / fail 90)
check "disk: 22 -> PASS"  "$(hm_classify_high 22 80 90)" "PASS"
check "disk: 85 -> WARN"  "$(hm_classify_high 85 80 90)" "WARN"
check "disk: 95 -> FAIL"  "$(hm_classify_high 95 80 90)" "FAIL"

# ===========================================================================
section "TEMPERATURE — sensor parsing (vcgencmd + thermal zone)"
# ---------------------------------------------------------------------------
check "vcgencmd: temp=47.2'C -> 47" "$(hm_parse_vcgencmd_temp "temp=47.2'C")" "47"
check "vcgencmd: from fixture -> 47" "$(hm_parse_vcgencmd_temp "$(cat "${FIX}/vcgencmd-temp.txt")")" "47"
check "vcgencmd: integer temp=55'C -> 55" "$(hm_parse_vcgencmd_temp "temp=55'C")" "55"
tests_run=$((tests_run+1)); hm_parse_vcgencmd_temp "garbage" >/dev/null 2>&1 && _fail "vcgencmd: garbage must error" || _pass "vcgencmd: garbage rejected"
check "thermal: 47234 -> 47"          "$(hm_parse_thermal_zone 47234)" "47"
check "thermal: from fixture -> 47"   "$(hm_parse_thermal_zone "$(cat "${FIX}/thermal-zone.txt")")" "47"
check "thermal: 82000 -> 82"          "$(hm_parse_thermal_zone 82000)" "82"
tests_run=$((tests_run+1)); hm_parse_thermal_zone "x" >/dev/null 2>&1 && _fail "thermal: garbage must error" || _pass "thermal: garbage rejected"

# ===========================================================================
section "THROTTLE — vcgencmd get_throttled decode"
# ---------------------------------------------------------------------------
check "throttled value: 0x50005 -> 327685" "$(hm_throttled_value "throttled=0x50005")" "327685"
check "throttled: 0x0 -> PASS"          "$(hm_classify_throttled "throttled=0x0")"    "PASS"
check "throttled: 0x0 from fixture"     "$(hm_classify_throttled "$(cat "${FIX}/throttled-ok.txt")")" "PASS"
check "throttled: 0x5 (now bits) -> FAIL"  "$(hm_classify_throttled "throttled=0x5")"  "FAIL"
check "throttled: now from fixture -> FAIL" "$(hm_classify_throttled "$(cat "${FIX}/throttled-now.txt")")" "FAIL"
check "throttled: 0x50000 (past) -> WARN"   "$(hm_classify_throttled "throttled=0x50000")" "WARN"
check "throttled: past from fixture -> WARN" "$(hm_classify_throttled "$(cat "${FIX}/throttled-past.txt")")" "WARN"
check "throttled: garbage -> SKIP (graceful)" "$(hm_classify_throttled "nonsense")" "SKIP"
check "throttled: empty -> SKIP"               "$(hm_classify_throttled "")"        "SKIP"
contains "throttled reasons: 0x1 = under-voltage now" "$(hm_throttled_reasons "throttled=0x1")" "under-voltage (now)"
contains "throttled reasons: 0x40000 = past throttle" "$(hm_throttled_reasons "throttled=0x40000")" "throttling has occurred"

# ===========================================================================
section "DISK — df parsing + dominant-consumer + percentage"
# ---------------------------------------------------------------------------
check "df %: root fixture -> 22"  "$(hm_parse_df_pct < "${FIX}/df-root.txt")" "22"
check "df %: warn fixture -> 85"  "$(hm_parse_df_pct < "${FIX}/df-warn.txt")" "85"
check "df %: fail fixture -> 95"  "$(hm_parse_df_pct < "${FIX}/df-fail.txt")" "95"
check "df avail-kb: root -> 356009792" "$(hm_parse_df_avail_kb < "${FIX}/df-root.txt")" "356009792"
check "df used-kb: root -> 100122080"  "$(hm_parse_df_used_kb < "${FIX}/df-root.txt")" "100122080"
# Robust to a Filesystem source WITH SPACES (parses from the right, not field 5).
check "df %: spaces-in-source -> 18"   "$(hm_parse_df_pct      < "${FIX}/df-spaces.txt")" "18"
check "df avail: spaces-in-source"     "$(hm_parse_df_avail_kb < "${FIX}/df-spaces.txt")" "826633964"
check "largest: docker beats backups" "$(printf 'backups\t5000\ndocker\t9000\n' | hm_largest)" "docker"
check "largest: backups beats docker" "$(printf 'backups\t9000\ndocker\t5000\n' | hm_largest)" "backups"
check "pct_of: 50 of 200 -> 25" "$(hm_pct_of 50 200)" "25"
check "pct_of: divide-by-zero guard -> 0" "$(hm_pct_of 5 0)" "0"

# ===========================================================================
section "MEMORY — free parsing + RAM/swap classification"
# ---------------------------------------------------------------------------
check "free: Mem total"      "$(hm_free_field Mem total     < "${FIX}/free.txt")" "8038400"
check "free: Mem available"  "$(hm_free_field Mem available < "${FIX}/free.txt")" "5400000"
check "free: Swap total"     "$(hm_free_field Swap total    < "${FIX}/free.txt")" "204800"
check "free: Swap used"      "$(hm_free_field Swap used     < "${FIX}/free.txt")" "10240"
check "free: Swap available is empty (no column)" "$(hm_free_field Swap available < "${FIX}/free.txt")" ""
tests_run=$((tests_run+1)); hm_free_field Bogus total < "${FIX}/free.txt" >/dev/null 2>&1 && _fail "free: missing row must error" || _pass "free: missing row rejected"

check "mem: 32% used -> PASS"   "$(hm_classify_mem 8038400 5400000 85 95)" "PASS"
check "mem: from pressure fixture -> WARN" \
  "$(hm_classify_mem "$(hm_free_field Mem total < "${FIX}/free-pressure.txt")" "$(hm_free_field Mem available < "${FIX}/free-pressure.txt")" 85 95)" "WARN"
check "mem: 95% used -> FAIL"   "$(hm_classify_mem 1000 50 85 95)" "FAIL"
check "mem: total 0 -> SKIP"    "$(hm_classify_mem 0 0 85 95)" "SKIP"
check "mem: non-numeric -> SKIP" "$(hm_classify_mem x y 85 95)" "SKIP"

check "swap: 5% -> PASS"        "$(hm_classify_swap 204800 10240 50 80)" "PASS"
check "swap: 63% -> WARN"       "$(hm_classify_swap 204800 130000 50 80)" "WARN"
check "swap: 87% -> FAIL"       "$(hm_classify_swap 204800 180000 50 80)" "FAIL"
check "swap: none configured -> PASS" "$(hm_classify_swap 0 0 50 80)" "PASS"
check "swap: from noswap fixture -> PASS" \
  "$(hm_classify_swap "$(hm_free_field Swap total < "${FIX}/free-noswap.txt")" "$(hm_free_field Swap used < "${FIX}/free-noswap.txt")" 50 80)" "PASS"

# ===========================================================================
section "CONTAINERS — docker stats parsing + near-limit detection"
# ---------------------------------------------------------------------------
check "size: 412MiB -> 412"  "$(hm_size_to_mib 412MiB)" "412"
check "size: 768MiB -> 768"  "$(hm_size_to_mib 768MiB)" "768"
check "size: 1.1GiB -> 1126" "$(hm_size_to_mib 1.1GiB)" "1126"
check "size: 1GiB -> 1024"   "$(hm_size_to_mib 1GiB)"   "1024"
check "size: 95.2MiB -> 95"  "$(hm_size_to_mib 95.2MiB)" "95"
check "size: 512MB -> 512"   "$(hm_size_to_mib 512MB)"  "512"
check "size: 900KiB -> 0"    "$(hm_size_to_mib 900KiB)" "0"
check "size: 0B -> 0"        "$(hm_size_to_mib 0B)"     "0"
tests_run=$((tests_run+1)); hm_size_to_mib "abc" >/dev/null 2>&1 && _fail "size: garbage must error" || _pass "size: garbage rejected"

check "stats used:  '120MiB / 128MiB' -> 120" "$(hm_stats_used_mib  "120MiB / 128MiB")" "120"
check "stats limit: '120MiB / 128MiB' -> 128" "$(hm_stats_limit_mib "120MiB / 128MiB")" "128"
check "pct_int: 53.65% -> 53" "$(hm_pct_int "53.65%")" "53"
check "pct_int: 3.20% -> 3"   "$(hm_pct_int "3.20%")"  "3"
tests_run=$((tests_run+1)); hm_pct_int "n/a" >/dev/null 2>&1 && _fail "pct_int: garbage must error" || _pass "pct_int: garbage rejected"

# Rows from the fixture, then verdicts.
ROWS="$(hm_stats_rows < "${FIX}/docker-stats.txt")"
check "rows: caddy line" "$(printf '%s\n' "${ROWS}" | awk -F'\t' '$1=="pi-system_caddy"{print $2"|"$3"|"$4}')" "120|128|93"
check "rows: n8n GiB parsed" "$(printf '%s\n' "${ROWS}" | awk -F'\t' '$1=="pi-system_n8n"{print $2"|"$3"|"$4}')" "1126|1536|73"
check "containers: caddy 93% -> WARN" "$(printf '%s\n' "${ROWS}" | hm_containers_verdict 85 95)" "WARN"
check "containers: fail fixture -> FAIL" "$(hm_stats_rows < "${FIX}/docker-stats-fail.txt" | hm_containers_verdict 85 95)" "FAIL"
check "containers: ok fixture -> PASS"   "$(hm_stats_rows < "${FIX}/docker-stats-ok.txt"   | hm_containers_verdict 85 95)" "PASS"
check "containers: no rows -> SKIP"      "$(printf '' | hm_containers_verdict 85 95)" "SKIP"
contains "near-limit: caddy named" "$(printf '%s\n' "${ROWS}" | hm_containers_near_limit 85)" "pi-system_caddy (93%)"
check "near-limit: ok fixture names nobody" "$(hm_stats_rows < "${FIX}/docker-stats-ok.txt" | hm_containers_near_limit 85)" ""

# ===========================================================================
section "FOLD — worst-of verdict (incl. SKIP precedence)"
# ---------------------------------------------------------------------------
check "worst: PASS,WARN -> WARN" "$(hm_worst PASS WARN)" "WARN"
check "worst: WARN,FAIL -> FAIL" "$(hm_worst WARN FAIL)" "FAIL"
check "worst: PASS,FAIL -> FAIL" "$(hm_worst PASS FAIL)" "FAIL"
check "worst: SKIP,PASS -> PASS (skip is lowest)" "$(hm_worst SKIP PASS)" "PASS"
check "worst: SKIP,WARN -> WARN" "$(hm_worst SKIP WARN)" "WARN"
check "worst: SKIP,SKIP -> SKIP" "$(hm_worst SKIP SKIP)" "SKIP"
check "worst: FAIL,SKIP -> FAIL" "$(hm_worst FAIL SKIP)" "FAIL"

# ===========================================================================
section "NOTIFIER — decision logic (only WARN/FAIL alert) + Kuma mapping"
# ---------------------------------------------------------------------------
tests_run=$((tests_run+1)); hm_should_notify PASS && _fail "notify: PASS must NOT alert" || _pass "notify: PASS is silent"
tests_run=$((tests_run+1)); hm_should_notify SKIP && _fail "notify: SKIP must NOT alert" || _pass "notify: SKIP is silent"
tests_run=$((tests_run+1)); hm_should_notify WARN && _pass "notify: WARN alerts" || _fail "notify: WARN must alert"
tests_run=$((tests_run+1)); hm_should_notify FAIL && _pass "notify: FAIL alerts" || _fail "notify: FAIL must alert"
check "kuma: PASS -> up"   "$(hm_kuma_status PASS)" "up"
check "kuma: WARN -> up"   "$(hm_kuma_status WARN)" "up"
check "kuma: SKIP -> up"   "$(hm_kuma_status SKIP)" "up"
check "kuma: FAIL -> down" "$(hm_kuma_status FAIL)" "down"
check "slug: strips specials" "$(hm_slug "health-FAIL!@#")" "health-FAIL---"

# ===========================================================================
section "INTEGRATION — end-to-end verdict via MOCKED seams + fixtures"
# ---------------------------------------------------------------------------
# Point every live seam at a fixture chosen per-scenario, then fold exactly the
# way the entrypoint does. Proves the pieces compose into the right verdict AND
# the right notify decision — without a Pi or Docker.
TEMP_FIX="${FIX}/vcgencmd-temp.txt"; THR_FIX="${FIX}/throttled-ok.txt"
DF_FIX="${FIX}/df-root.txt"; FREE_FIX="${FIX}/free.txt"; STATS_FIX="${FIX}/docker-stats-ok.txt"
hm_vcgencmd_temp()      { cat "${TEMP_FIX}"; }
hm_vcgencmd_throttled() { cat "${THR_FIX}"; }
hm_df()                 { cat "${DF_FIX}"; }       # ignores its path arg (fixture)
hm_free()               { cat "${FREE_FIX}"; }
hm_docker_available()   { return 0; }
hm_docker_stats()       { cat "${STATS_FIX}"; }

assess() {   # echoes the folded overall verdict, mirroring the entrypoint
  local overall="PASS" v t
  t="$(hm_parse_vcgencmd_temp "$(hm_vcgencmd_temp)")"
  overall="$(hm_worst "${overall}" "$(hm_classify_high "${t}" 70 80)")"
  v="$(hm_classify_throttled "$(hm_vcgencmd_throttled)")"; [[ "${v}" != "SKIP" ]] && overall="$(hm_worst "${overall}" "${v}")"
  overall="$(hm_worst "${overall}" "$(hm_classify_high "$(hm_df / | hm_parse_df_pct)" 80 90)")"
  overall="$(hm_worst "${overall}" "$(hm_classify_mem "$(hm_free | hm_free_field Mem total)" "$(hm_free | hm_free_field Mem available)" 85 95)")"
  overall="$(hm_worst "${overall}" "$(hm_classify_swap "$(hm_free | hm_free_field Swap total)" "$(hm_free | hm_free_field Swap used)" 50 80)")"
  v="$(hm_docker_stats | hm_stats_rows | hm_containers_verdict 85 95)"; [[ "${v}" != "SKIP" ]] && overall="$(hm_worst "${overall}" "${v}")"
  echo "${overall}"
}

# Scenario A — everything healthy -> PASS, and PASS is SILENT.
TEMP_FIX="${FIX}/vcgencmd-temp.txt"; THR_FIX="${FIX}/throttled-ok.txt"; DF_FIX="${FIX}/df-root.txt"; FREE_FIX="${FIX}/free.txt"; STATS_FIX="${FIX}/docker-stats-ok.txt"
A="$(assess)"
check "scenario healthy -> PASS" "${A}" "PASS"
tests_run=$((tests_run+1)); hm_should_notify "${A}" && _fail "healthy must not notify" || _pass "healthy stays silent"

# Scenario B — disk 85% full -> WARN, and WARN NOTIFIES.
DF_FIX="${FIX}/df-warn.txt"
B="$(assess)"
check "scenario disk 85% -> WARN" "${B}" "WARN"
tests_run=$((tests_run+1)); hm_should_notify "${B}" && _pass "warn notifies" || _fail "warn must notify"
DF_FIX="${FIX}/df-root.txt"   # reset

# Scenario C — active throttling -> FAIL, and FAIL NOTIFIES (down on Kuma).
THR_FIX="${FIX}/throttled-now.txt"
Cc="$(assess)"
check "scenario throttled-now -> FAIL" "${Cc}" "FAIL"
check "scenario FAIL -> kuma down" "$(hm_kuma_status "${Cc}")" "down"
tests_run=$((tests_run+1)); hm_should_notify "${Cc}" && _pass "fail notifies" || _fail "fail must notify"
THR_FIX="${FIX}/throttled-ok.txt"  # reset

# Scenario D — memory pressure + swap -> at least WARN.
FREE_FIX="${FIX}/free-pressure.txt"
D="$(assess)"
tests_run=$((tests_run+1)); [[ "${D}" == "WARN" || "${D}" == "FAIL" ]] && _pass "memory pressure -> ${D}" || _fail "memory pressure should WARN/FAIL, got ${D}"
FREE_FIX="${FIX}/free.txt"  # reset

# ===========================================================================
section "REAL SCRIPTS — syntax + the installed cron line shape"
# ---------------------------------------------------------------------------
for f in "${LIB}" "${ENTRY}" "${CRON}"; do
  tests_run=$((tests_run+1))
  if bash -n "${f}" 2>/dev/null; then _pass "syntax ok: ${f#${PROJECT_ROOT}/}"
  else _fail "syntax error in ${f#${PROJECT_ROOT}/}"; fi
done
# --help must succeed and stay read-only.
tests_run=$((tests_run+1))
if bash "${ENTRY}" --help >/dev/null 2>&1; then _pass "health-monitor.sh --help exits 0"; else _fail "health-monitor.sh --help failed"; fi
# The cron installer must schedule the quiet, status-dir run (the contract the
# scheduled monitoring depends on).
CRON_SRC="$(cat "${CRON}")"
contains "cron line runs health-monitor.sh --quiet --status-dir" "${CRON_SRC}" "scripts/health-monitor.sh --quiet --status-dir"
contains "cron block is idempotently marked" "${CRON_SRC}" "pi-system health-monitor schedule"

# Default thresholds in the entrypoint must be sane (warn < fail for each).
defpair() {
  local label="$1" wvar="$2" fvar="$3" w f
  w="$(grep -oE "${wvar}:-[0-9]+" "${ENTRY}" | head -1 | grep -oE '[0-9]+$')"
  f="$(grep -oE "${fvar}:-[0-9]+" "${ENTRY}" | head -1 | grep -oE '[0-9]+$')"
  tests_run=$((tests_run+1))
  if [[ -n "${w}" && -n "${f}" && "${w}" -lt "${f}" ]]; then _pass "default ${label}: warn ${w} < fail ${f}"
  else _fail "default ${label}: warn '${w}' must be < fail '${f}'"; fi
}
defpair "temp" HEALTH_TEMP_WARN HEALTH_TEMP_FAIL
defpair "disk" HEALTH_DISK_WARN HEALTH_DISK_FAIL
defpair "mem"  HEALTH_MEM_WARN  HEALTH_MEM_FAIL
defpair "swap" HEALTH_SWAP_WARN HEALTH_SWAP_FAIL
defpair "ctr"  HEALTH_CTR_WARN  HEALTH_CTR_FAIL

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
