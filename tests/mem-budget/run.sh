#!/usr/bin/env bash
# ===========================================================================
# pi-system — memory-budget TEST HARNESS
# ---------------------------------------------------------------------------
# Exercises the PURE decision logic of scripts/mem-budget.sh (via the sourced
# library scripts/lib/mem-budget-lib.sh) against FIXTURES and MOCKED seams, so
# its summation and PASS/WARN/FAIL verdicts are verified WITHOUT Docker or a
# real Pi — mirroring tests/preflight/run.sh.
#
# Coverage (each maps to a real way the budget could be wrong):
#   * memory-value conversion       -> mb_to_mib / mb_literal_mib (units + bytes)
#   * per-service limit parsing      -> mb_service_limits on fixture compose files
#   * MAX over limits+reservations   -> beta picks 512M, not the 128M reservation
#   * missing-limit detection        -> delta has no limit -> empty -> MISSING
#   * profile expansion + dedup      -> mb_flatten (profile-of-profiles, literals)
#   * reference-cycle guard          -> ring1 <-> ring2 terminates
#   * OS-headroom math               -> mb_safe_mib (RAM - reserve, floored at 0)
#   * verdict bands                  -> mb_verdict_numeric / mb_overall_verdict
#   * a profile that FITS            -> integration budget() -> PASS
#   * a profile that EXCEEDS RAM     -> integration budget() -> FAIL
#   * missing limit forces FAIL      -> integration budget() on "broken"
#   * the REAL repo                  -> every service has a limit; every real
#                                       boot-profiles member resolves (no typos)
#
# Usage:   ./tests/mem-budget/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${PROJECT_ROOT}/scripts/lib/mem-budget-lib.sh"
FIX="${SCRIPT_DIR}/fixtures"
REAL_CONF="${PROJECT_ROOT}/infrastructure/boot-profiles.conf"

if [[ ! -f "${LIB}" ]]; then
  printf 'FATAL: library not found: %s\n' "${LIB}" >&2
  exit 2
fi
# shellcheck source=../../scripts/lib/mem-budget-lib.sh
source "${LIB}"

# --- Colours (off when not a TTY) ------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; O=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; O=''
fi

# --- Tiny assertion framework (same shape as tests/preflight/run.sh) -------
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

# Look up one service's MiB from a "service<TAB>mib" stream on stdin.
field_for() { awk -F'\t' -v k="$1" '$1==k {print $2; found=1} END{ if(!found) print "<absent>" }'; }

# ===========================================================================
section "CONVERT — memory values to MiB (pure)"
# ---------------------------------------------------------------------------
check "to_mib: 256M"        "$(mb_to_mib 256M)"        "256"
check "to_mib: 512m"        "$(mb_to_mib 512m)"        "512"
check "to_mib: 1G"          "$(mb_to_mib 1G)"          "1024"
check "to_mib: 2g"          "$(mb_to_mib 2g)"          "2048"
check "to_mib: 128MB"       "$(mb_to_mib 128MB)"       "128"
check "to_mib: 1024 (bytes)" "$(mb_to_mib 1024)"       "0"      # bare int = bytes
check "to_mib: 268435456 B" "$(mb_to_mib 268435456)"   "256"    # 256 MiB in bytes
check "to_mib: 524288K"     "$(mb_to_mib 524288K)"     "512"    # KiB -> MiB
check "to_mib: quoted"      "$(mb_to_mib '"256M"')"    "256"
tests_run=$((tests_run+1)); mb_to_mib "abc"  >/dev/null 2>&1 && _fail "to_mib: garbage must error" || _pass "to_mib: garbage rejected"
tests_run=$((tests_run+1)); mb_to_mib ""     >/dev/null 2>&1 && _fail "to_mib: empty must error"   || _pass "to_mib: empty rejected"

# literal allowance: bare int is MiB (not bytes), units still work.
check "literal: 512 -> MiB"  "$(mb_literal_mib 512)"  "512"
check "literal: 1G -> 1024"  "$(mb_literal_mib 1G)"   "1024"

# ===========================================================================
section "PARSE — per-service limits from compose (pure)"
# ---------------------------------------------------------------------------
A_LIMITS="$(mb_service_limits "${FIX}/compose-a.yml")"
check "parse: alpha = 256"                 "$(printf '%s\n' "${A_LIMITS}" | field_for alpha)" "256"
check "parse: beta = 512 (MAX, not 128)"   "$(printf '%s\n' "${A_LIMITS}" | field_for beta)"  "512"
check "parse: volume/network not a service" "$(printf '%s\n' "${A_LIMITS}" | field_for internal)" "<absent>"
check "parse: alpha_data not a service"     "$(printf '%s\n' "${A_LIMITS}" | field_for alpha_data)" "<absent>"

B_LIMITS="$(mb_service_limits "${FIX}/compose-b.yml")"
check "parse: gamma = 1024 (mem_limit)"    "$(printf '%s\n' "${B_LIMITS}" | field_for gamma)" "1024"
check "parse: delta = (empty) MISSING"     "$(printf '%s\n' "${B_LIMITS}" | field_for delta)" ""
check "parse: env key not a service"       "$(printf '%s\n' "${B_LIMITS}" | field_for FOO)"   "<absent>"

# ===========================================================================
section "FLATTEN — profile expansion, dedup, cycle guard (pure)"
# ---------------------------------------------------------------------------
check "flatten: small"  "$(mb_flatten "${FIX}/profiles.conf" small  | paste -sd' ' -)" "alpha beta"
check "flatten: medium (profile-of-profile)" \
      "$(mb_flatten "${FIX}/profiles.conf" medium | paste -sd' ' -)" "alpha beta gamma"
check "flatten: big (+ literals)" \
      "$(mb_flatten "${FIX}/profiles.conf" big    | paste -sd' ' -)" "alpha beta gamma app-x=2048 app-y=2048"
check "flatten: cycle terminates" \
      "$(mb_flatten "${FIX}/profiles.conf" ring1  | paste -sd' ' -)" "beta alpha"
check "flatten: dedup across two profiles" \
      "$(mb_flatten "${FIX}/profiles.conf" small medium | paste -sd' ' -)" "alpha beta gamma"

# ===========================================================================
section "HEADROOM + VERDICT — the budget math (pure)"
# ---------------------------------------------------------------------------
check "safe: 4096 - 1024 = 3072" "$(mb_safe_mib 4096 1024)" "3072"
check "safe: reserve == total -> 0" "$(mb_safe_mib 1024 1024)" "0"
check "safe: reserve > total -> 0 (floored)" "$(mb_safe_mib 1024 2048)" "0"

check "verdict: 768 of 3072 -> PASS"  "$(mb_verdict_numeric 768 3072)" "PASS"
check "verdict: 800 of 1000 -> PASS (<=85%)" "$(mb_verdict_numeric 800 1000)" "PASS"
check "verdict: 900 of 1000 -> WARN (>85%)"  "$(mb_verdict_numeric 900 1000)" "WARN"
check "verdict: 1000 of 1000 -> WARN (==100%)" "$(mb_verdict_numeric 1000 1000)" "WARN"
check "verdict: 1001 of 1000 -> FAIL"  "$(mb_verdict_numeric 1001 1000)" "FAIL"
check "verdict: safe 0 -> FAIL"        "$(mb_verdict_numeric 1 0)" "FAIL"

check "overall: missing forces FAIL"   "$(mb_overall_verdict 1 100 9999)" "FAIL"
check "overall: no missing -> numeric" "$(mb_overall_verdict 0 768 3072)" "PASS"

# ===========================================================================
section "REGISTRY — the REAL boot-profiles.conf vs the REAL repo (integrity)"
# ---------------------------------------------------------------------------
# Build the real service -> MiB map with the DEFAULT seams (real compose files).
declare -A REAL_MAP=()
declare -a REAL_ORDER=()
while IFS=$'\t' read -r s m; do
  [[ -n "${s}" ]] || continue
  REAL_MAP["${s}"]="${m}"; REAL_ORDER+=("${s}")
done < <(MB_PROJECT_ROOT="${PROJECT_ROOT}" mb_build_service_map)

tests_run=$((tests_run+1))
if (( ${#REAL_ORDER[@]} >= 10 )); then _pass "real repo: discovered ${#REAL_ORDER[@]} services"
else _fail "real repo: expected to discover the platform services, found ${#REAL_ORDER[@]}"; fi

# EVERY real service must declare a memory limit (Part A invariant).
nolimit=0
for s in "${REAL_ORDER[@]}"; do
  [[ -z "${REAL_MAP[${s}]}" ]] && { _fail "real repo: service '${s}' has NO memory limit"; nolimit=1; tests_run=$((tests_run+1)); }
done
tests_run=$((tests_run+1)); (( nolimit == 0 )) && _pass "real repo: every service declares a memory limit"

# A few known anchors so a wrong parse can't pass silently.
check "real: keycloak = 768" "${REAL_MAP[keycloak]:-<absent>}" "768"
check "real: caddy = 128"    "${REAL_MAP[caddy]:-<absent>}"    "128"
check "real: postgres = 256" "${REAL_MAP[postgres]:-<absent>}" "256"

# EVERY member of EVERY real profile must resolve to a known service or a
# label=MiB literal — i.e. no typos in infrastructure/boot-profiles.conf.
if [[ -f "${REAL_CONF}" ]]; then
  unresolved=""
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    while IFS= read -r e; do
      [[ -n "${e}" ]] || continue
      if [[ "${e}" == *=* ]]; then
        mb_literal_mib "${e#*=}" >/dev/null 2>&1 || unresolved+=" ${p}:${e}"
      elif [[ -z "${REAL_MAP[${e}]+x}" ]]; then
        unresolved+=" ${p}:${e}"
      fi
    done < <(mb_flatten "${REAL_CONF}" "${p}")
  done < <(mb_profile_names "${REAL_CONF}")
  check "real profiles: all members resolve (no typos)" "${unresolved}" ""
else
  _skip "real boot-profiles.conf integrity (file not found)"
fi

# ===========================================================================
section "INTEGRATION — fits / exceeds / missing, via MOCKED compose seam"
# ---------------------------------------------------------------------------
# Point the compose-files seam at the fixtures, then build the fixture map.
mb_compose_files() { printf '%s\n' "${FIX}/compose-a.yml" "${FIX}/compose-b.yml"; }
declare -A TMAP=()
while IFS=$'\t' read -r s m; do [[ -n "${s}" ]] && TMAP["${s}"]="${m}"; done < <(mb_build_service_map)

check "map: fixture alpha=256"  "${TMAP[alpha]:-<absent>}"  "256"
check "map: fixture gamma=1024" "${TMAP[gamma]:-<absent>}"  "1024"
check "map: fixture delta present"         "${TMAP[delta]+present}"  "present"
check "map: fixture delta empty (missing)" "${TMAP[delta]-<absent>}" ""

# budget RAM RESERVE CONF tokens...  ->  "VERDICT used safe missing"
budget() {
  local ram="$1" reserve="$2" conf="$3"; shift 3
  local used=0 miss=0 e val mib
  while IFS= read -r e; do
    [[ -n "${e}" ]] || continue
    if [[ "${e}" == *=* ]]; then
      val="${e#*=}"
      if mib="$(mb_literal_mib "${val}")" && [[ -n "${mib}" ]]; then used=$((used+mib)); else miss=$((miss+1)); fi
    elif [[ -n "${TMAP[${e}]+x}" ]]; then
      mib="${TMAP[${e}]}"
      if [[ -n "${mib}" ]]; then used=$((used+mib)); else miss=$((miss+1)); fi
    else
      miss=$((miss+1))
    fi
  done < <(mb_flatten "${conf}" "$@")
  local safe verdict
  safe="$(mb_safe_mib "${ram}" "${reserve}")"
  verdict="$(mb_overall_verdict "${miss}" "${used}" "${safe}")"
  echo "${verdict} ${used} ${safe} ${miss}"
}

# A profile that FITS: small=768, RAM 4096 - reserve 1024 = safe 3072 -> PASS.
check "fits: small on 4096/1024 -> PASS 768/3072" "$(budget 4096 1024 "${FIX}/profiles.conf" small)" "PASS 768 3072 0"

# A profile that EXCEEDS RAM: big=5888 > safe 3072 -> FAIL.
check "exceeds: big on 4096/1024 -> FAIL"          "$(budget 4096 1024 "${FIX}/profiles.conf" big)"   "FAIL 5888 3072 0"

# Missing-limit detection: broken = alpha(256) + delta(no limit) -> FAIL, miss=1.
check "missing: broken -> FAIL, used 256, miss 1"  "$(budget 4096 1024 "${FIX}/profiles.conf" broken)" "FAIL 256 3072 1"

# OS-HEADROOM math changes the verdict: same 'small' (768) but a fat reserve of
# 3500 leaves only safe=596, so it now FAILs — proving the reserve is applied.
check "headroom: small on 4096/3500 -> FAIL (596 safe)" "$(budget 4096 3500 "${FIX}/profiles.conf" small)" "FAIL 768 596 0"
# And the WARN band: used 2700 of safe 3072 (>85% = 2611) -> WARN.
check "headroom: medium+lit on 4096/1024 -> WARN" "$(budget 4096 1024 "${FIX}/profiles.conf" medium app-z=908)" "WARN 2700 3072 0"

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
