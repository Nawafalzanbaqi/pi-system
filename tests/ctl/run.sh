#!/usr/bin/env bash
# ===========================================================================
# pi-system — UNIFIED CONTROL test harness
# ---------------------------------------------------------------------------
# Exercises the PURE decision logic of scripts/pi + scripts/status.sh (via the
# sourced library scripts/lib/ctl-lib.sh) against FIXTURES and MOCKED seams, so
# the dispatcher's routing/sequencing and the status aggregation are verified
# WITHOUT Docker or a real Pi — mirroring tests/{preflight,mem-budget,startup,
# health-monitor}/run.sh.
#
# Coverage (each maps to a real way the control layer could go wrong):
#   * subcommand ROUTING                 -> ctl_route across every verb + unknown
#   * flag detection / pass-through      -> ctl_has_flag / ctl_value_flag /
#                                           ctl_scope_tokens / ctl_skip_flags /
#                                           ctl_forward_startup_args (+ --skip-checks)
#   * `up`/`check` STEP ORDER            -> ctl_up_steps / ctl_check_steps across
#                                           default / dry-run / skip combinations
#   * SEQUENCING + HALT (mock oracle)    -> ctl_run_sequence stops at first failure
#   * SEQUENCING via the REAL oracle over MOCKED SEAMS -> `up` calls
#                                           preflight -> mem-budget -> startup in
#                                           that order and HALTS if an earlier step
#                                           fails (mem-budget/startup not called)
#   * SCOPE resolution                   -> ctl_preflight_components vs fixture conf
#   * STATUS labels / probe / verdict    -> ctl_status_label / ctl_probe_service
#                                           (mocked container state) / ctl_status_tally
#                                           / ctl_status_overall / ctl_health_verdict
#   * INTEGRITY vs the real repo         -> seam target scripts exist; the three new
#                                           files parse; real core scope is correct
#
# Usage:   ./tests/ctl/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${PROJECT_ROOT}/scripts/lib/ctl-lib.sh"
FIX="${SCRIPT_DIR}/fixtures"
REAL_CONF="${PROJECT_ROOT}/infrastructure/boot-profiles.conf"

if [[ ! -f "${LIB}" ]]; then
  printf 'FATAL: library not found: %s\n' "${LIB}" >&2
  exit 2
fi
export CTL_PROJECT_ROOT="${PROJECT_ROOT}"
export SU_PROJECT_ROOT="${PROJECT_ROOT}"
# shellcheck source=../../scripts/lib/ctl-lib.sh
source "${LIB}"

# --- Colours (off when not a TTY) ------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; O=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; O=''
fi

# --- Tiny assertion framework (same shape as the sibling suites) -----------
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

# ===========================================================================
section "ROUTE — subcommand routing (pure)"
# ---------------------------------------------------------------------------
check "route up"      "$(ctl_route up)"      "up"
check "route down"    "$(ctl_route down)"    "down"
check "route status"  "$(ctl_route status)"  "status"
check "route check"   "$(ctl_route check)"   "check"
check "route health"  "$(ctl_route health)"  "health"
check "route doctor"  "$(ctl_route doctor)"  "doctor"
check "route runbook->doctor" "$(ctl_route runbook)" "doctor"
check "route help"    "$(ctl_route help)"    "help"
check "route -h"      "$(ctl_route -h)"      "help"
check "route --help"  "$(ctl_route --help)"  "help"
check "route empty"   "$(ctl_route '')"      "help"
check "route bogus"   "$(ctl_route bogus)"   "unknown"

# ===========================================================================
section "FLAGS — detection & pass-through (pure)"
# ---------------------------------------------------------------------------
ctl_has_flag --dry-run --profile core --dry-run && _pass "has_flag: present" || _fail "has_flag: should find --dry-run"; tests_run=$((tests_run+1))
ctl_has_flag --dry-run --profile core && _fail "has_flag: false positive" || _pass "has_flag: absent"; tests_run=$((tests_run+1))

check "value_flag --ram space" "$(ctl_value_flag --ram --profile dev --ram 16384)" "16384"
check "value_flag --ram equals" "$(ctl_value_flag --ram --ram=8192 --yes)" "8192"
ctl_value_flag --ram --profile dev >/dev/null && _fail "value_flag: should be absent" || _pass "value_flag: absent -> rc1"; tests_run=$((tests_run+1))

# scope tokens (values of --profile / --services, comma/space split)
check "scope: --profile"      "$(ctl_scope_tokens --profile dev | paste -sd' ' -)"          "dev"
check "scope: --profile="     "$(ctl_scope_tokens --profile=auth | paste -sd' ' -)"         "auth"
check "scope: --services csv" "$(ctl_scope_tokens --services postgres,redis | paste -sd' ' -)" "postgres redis"
check "scope: --services=spc" "$(ctl_scope_tokens --services='mysql mongo' | paste -sd' ' -)"  "mysql mongo"
check "scope: profile+services" "$(ctl_scope_tokens --profile core --services mysql --yes | paste -sd' ' -)" "core mysql"
check "scope: none"           "$(ctl_scope_tokens --dry-run -y | paste -sd' ' -)"            ""

# skip-flag decoding: "<dry> <skip_pf> <skip_mb>"
check "skip: none"            "$(ctl_skip_flags --profile core)"           "0 0 0"
check "skip: --dry-run"       "$(ctl_skip_flags --dry-run)"               "1 0 0"
check "skip: --skip-checks"   "$(ctl_skip_flags --skip-checks)"           "0 1 1"
check "skip: --skip-preflight" "$(ctl_skip_flags --skip-preflight)"       "0 1 0"
check "skip: --skip-mem-budget" "$(ctl_skip_flags --skip-mem-budget)"     "0 0 1"

# forward to startup: original args PLUS --skip-checks appended last.
mapfile -t FWD < <(ctl_forward_startup_args --profile core --dry-run)
check "forward: arg count (3 in -> 4 out)" "${#FWD[@]}" "4"
check "forward: original preserved"        "${FWD[0]} ${FWD[1]} ${FWD[2]}" "--profile core --dry-run"
check "forward: --skip-checks appended"    "${FWD[-1]}" "--skip-checks"

# ===========================================================================
section "STEPS — up/check step order (pure)"
# ---------------------------------------------------------------------------
check "up: default order"        "$(ctl_up_steps 0 0 0 | paste -sd' ' -)" "preflight mem-budget startup"
check "up: dry-run -> startup"   "$(ctl_up_steps 1 0 0 | paste -sd' ' -)" "startup"
check "up: skip-checks -> startup" "$(ctl_up_steps 0 1 1 | paste -sd' ' -)" "startup"
check "up: skip-preflight"       "$(ctl_up_steps 0 1 0 | paste -sd' ' -)" "mem-budget startup"
check "up: skip-mem-budget"      "$(ctl_up_steps 0 0 1 | paste -sd' ' -)" "preflight startup"
check "check: default pair"      "$(ctl_check_steps 0 0 | paste -sd' ' -)" "preflight mem-budget"
check "check: skip-preflight"    "$(ctl_check_steps 1 0 | paste -sd' ' -)" "mem-budget"
check "check: both skipped empty" "$(ctl_check_steps 1 1 | paste -sd' ' -)" ""

# ===========================================================================
section "HALT — a failed step stops the rest (ctl_run_sequence, mock oracle)"
# ---------------------------------------------------------------------------
FAIL_AT=""
mock_oracle() { [[ -n "${FAIL_AT}" && "$1" == "${FAIL_AT}" ]] && return 1 || return 0; }

FAIL_AT=""
ctl_run_sequence mock_oracle preflight mem-budget startup; rc=$?
check "all ok -> rc 0"            "${rc}" "0"
check "all ok -> ran every step"  "$(printf '%s ' "${CTL_EXECUTED[@]}")" "preflight mem-budget startup "

FAIL_AT="mem-budget"
ctl_run_sequence mock_oracle preflight mem-budget startup; rc=$?
check "mid fail -> rc 1"          "${rc}" "1"
check "mid fail -> halts there"   "$(printf '%s ' "${CTL_EXECUTED[@]}")" "preflight mem-budget "

FAIL_AT="preflight"
ctl_run_sequence mock_oracle preflight mem-budget startup; rc=$?
check "first fail -> only first ran" "$(printf '%s ' "${CTL_EXECUTED[@]}")" "preflight "

# ===========================================================================
section "SEQUENCE — real oracle (ctl_step_run) over MOCKED SEAMS"
# ---------------------------------------------------------------------------
# Prove the headline contract: `up` invokes preflight -> mem-budget -> startup in
# that order and HALTS if an earlier step fails, using mocked seams (no Docker).
CALLS=""
ctl_run_preflight()  { CALLS+="preflight ";  return "${RC_PF:-0}"; }
ctl_run_mem_budget() { CALLS+="mem-budget "; return "${RC_MB:-0}"; }
ctl_run_startup()    { CALLS+="startup ";    return "${RC_SU:-0}"; }

# Happy path: all three pass, in order.
CALLS=""; CTL_RESULTS=(); RC_PF=0; RC_MB=0; RC_SU=0
mapfile -t steps < <(ctl_up_steps 0 0 0)
ctl_run_sequence ctl_step_run "${steps[@]}"; rc=$?
check "seam happy: rc 0"          "${rc}" "0"
check "seam happy: call order"    "${CALLS}" "preflight mem-budget startup "
check "seam happy: executed all"  "$(printf '%s ' "${CTL_EXECUTED[@]}")" "preflight mem-budget startup "
check "seam happy: 3 results"     "${#CTL_RESULTS[@]}" "3"
check "seam happy: startup PASS"  "${CTL_RESULTS[-1]}" "$(printf 'startup\tPASS')"

# Preflight fails: mem-budget + startup are NEVER called.
CALLS=""; CTL_RESULTS=(); RC_PF=1; RC_MB=0; RC_SU=0
mapfile -t steps < <(ctl_up_steps 0 0 0)
ctl_run_sequence ctl_step_run "${steps[@]}"; rc=$?
check "seam pf-fail: rc 1"        "${rc}" "1"
check "seam pf-fail: only preflight called" "${CALLS}" "preflight "
check "seam pf-fail: preflight FAIL recorded" "${CTL_RESULTS[-1]}" "$(printf 'preflight\tFAIL')"

# Mem-budget fails: startup is NEVER called.
CALLS=""; CTL_RESULTS=(); RC_PF=0; RC_MB=1; RC_SU=0
mapfile -t steps < <(ctl_up_steps 0 0 0)
ctl_run_sequence ctl_step_run "${steps[@]}"; rc=$?
check "seam mb-fail: rc 1"        "${rc}" "1"
check "seam mb-fail: startup not called" "${CALLS}" "preflight mem-budget "

# `check` uses the SAME oracle but only the read-only pair (no startup).
CALLS=""; CTL_RESULTS=(); RC_PF=0; RC_MB=0; RC_SU=0
mapfile -t steps < <(ctl_check_steps 0 0)
ctl_run_sequence ctl_step_run "${steps[@]}"; rc=$?
check "check seam: pair only, no startup" "${CALLS}" "preflight mem-budget "

# The remaining sections don't invoke these run seams; the real library (with
# the real seams) is re-sourced after the probe-mock section below.

# ===========================================================================
section "SCOPE — profile -> preflight components (pure, fixture conf)"
# ---------------------------------------------------------------------------
check "scope core"   "$(ctl_preflight_components "${FIX}/profiles.conf" core | paste -sd' ' -)"   "proxy management dashboard"
check "scope dev"    "$(ctl_preflight_components "${FIX}/profiles.conf" dev  | paste -sd' ' -)"   "proxy management dashboard postgres cache"
check "scope auth"   "$(ctl_preflight_components "${FIX}/profiles.conf" auth | paste -sd' ' -)"   "proxy management dashboard auth"
check "scope automation" "$(ctl_preflight_components "${FIX}/profiles.conf" automation | paste -sd' ' -)" "proxy management dashboard automation"
check "scope service postgres" "$(ctl_preflight_components "${FIX}/profiles.conf" postgres | paste -sd' ' -)" "postgres"
check "scope literal ignored"  "$(ctl_preflight_components "${FIX}/profiles.conf" app-x=512 | paste -sd' ' -)" ""

# ===========================================================================
section "STATUS — label / verdict logic (pure)"
# ---------------------------------------------------------------------------
# Human label from inspect fields (health, state, restarting).
check "label healthy"     "$(ctl_status_label healthy   running false)" "healthy"
check "label unhealthy"   "$(ctl_status_label unhealthy running false)" "unhealthy"
check "label starting"    "$(ctl_status_label starting  running false)" "starting"
check "label running"     "$(ctl_status_label none      running false)" "running"
check "label restarting"  "$(ctl_status_label none      running true)"  "restarting"
check "label created->start" "$(ctl_status_label none   created false)" "starting"
check "label exited"      "$(ctl_status_label none      exited  false)" "exited"
check "label absent"      "$(ctl_status_label none      ''      false)" "absent"

# Overall roll-up: broken / up / host -> UP | DOWN | DEGRADED
check "overall: up healthy"     "$(ctl_status_overall 0 5 PASS)" "UP"
check "overall: up host-warn"   "$(ctl_status_overall 0 5 WARN)" "UP"
check "overall: broken->degraded" "$(ctl_status_overall 1 4 PASS)" "DEGRADED"
check "overall: host-fail->degraded" "$(ctl_status_overall 0 5 FAIL)" "DEGRADED"
check "overall: nothing up->down" "$(ctl_status_overall 0 0 PASS)" "DOWN"

# Tally folding: "<broken> <up> <off> <waiting>" + verdict
check "tally READY"  "$(ctl_status_tally 0 0 0 0 READY)"  "0 1 0 0"
check "tally FAIL"   "$(ctl_status_tally 0 0 0 0 FAIL)"   "1 0 0 0"
check "tally ABSENT" "$(ctl_status_tally 0 0 0 0 ABSENT)" "0 0 1 0"
check "tally WAIT"   "$(ctl_status_tally 0 0 0 0 WAIT)"   "0 1 0 1"

# Host-health verdict extraction (plain + colourless lines).
check "health PASS" "$(ctl_health_verdict 'pi-system health
VERDICT: PASS — host is healthy.')" "PASS"
check "health WARN" "$(ctl_health_verdict 'VERDICT: WARN — attention recommended.')" "WARN"
check "health FAIL" "$(ctl_health_verdict 'VERDICT: FAIL — a resource is over its threshold.')" "FAIL"
check "health none -> UNKNOWN" "$(ctl_health_verdict 'no verdict here')" "UNKNOWN"

# ===========================================================================
section "DOCTOR — next-command recommendation (pure)"
# ---------------------------------------------------------------------------
# The whole-system verdict word, extracted from a captured status.sh run.
check "verdict UP"       "$(ctl_status_verdict_word 'VERDICT: UP — 3 group(s) running.')"   "UP"
check "verdict DOWN"     "$(ctl_status_verdict_word 'VERDICT: DOWN — nothing is running.')" "DOWN"
check "verdict DEGRADED" "$(ctl_status_verdict_word 'VERDICT: DEGRADED — 1 broken.')"       "DEGRADED"
check "verdict UNKNOWN word" "$(ctl_status_verdict_word 'VERDICT: UNKNOWN — Docker not reachable.')" "UNKNOWN"
check "verdict absent -> UNKNOWN" "$(ctl_status_verdict_word 'no verdict here')"            "UNKNOWN"

# The recommendation: echoes "<command>\t<reason>"; assert the COMMAND per branch.
nc_cmd() { ctl_next_command "$1" "$2" "$3" | cut -f1; }
check "next: no .env -> setup"        "$(nc_cmd 0 0 UNKNOWN)"  "./scripts/setup.sh"
check "next: no .env wins over rest"  "$(nc_cmd 0 1 UP)"       "./scripts/setup.sh"
check "next: secrets bad -> audit"    "$(nc_cmd 1 0 DOWN)"     "./scripts/check-secrets.sh"
check "next: ready+down -> up core"   "$(nc_cmd 1 1 DOWN)"     "./scripts/pi up --profile core"
check "next: degraded -> status"      "$(nc_cmd 1 1 DEGRADED)" "./scripts/pi status"
check "next: up -> status"            "$(nc_cmd 1 1 UP)"       "./scripts/pi status"
check "next: unknown -> check core"   "$(nc_cmd 1 1 UNKNOWN)"  "./scripts/pi check --profile core"
# Every branch must also carry a non-empty reason after the TAB.
check "next: reason present"          "$( [[ -n "$(ctl_next_command 1 1 DOWN | cut -f2)" ]] && echo yes || echo no )" "yes"

# ===========================================================================
section "STATUS — per-service probe over MOCKED container state"
# ---------------------------------------------------------------------------
# Mock the two read-only seams the probe uses: service->id and id->inspect line.
declare -A MOCK_ID=(
  [caddy]="cid_caddy" [postgres]="cid_pg" [keycloak]="cid_kc" [redis]="cid_redis"
)   # any service not listed -> empty id (no container)
declare -A MOCK_INSPECT=(
  [cid_caddy]=$'running\tfalse\t0\tnone'        # no healthcheck, running   -> running/READY
  [cid_pg]=$'running\tfalse\t0\thealthy'        # healthcheck healthy       -> healthy/READY
  [cid_kc]=$'exited\tfalse\t0\tnone'            # exited                     -> exited/FAIL
  [cid_redis]=$'running\tfalse\t0\tunhealthy'   # healthcheck unhealthy      -> unhealthy/FAIL
)
su_service_container_id() { local s="$1"; printf '%s' "${MOCK_ID[${s}]:-}"; }
su_inspect()              { printf '%s' "${MOCK_INSPECT[$1]:-}"; }

probe() { ctl_probe_service "$1" --project-directory x | tr '\t' '/'; }
check "probe caddy running"   "$(probe caddy)"    "running/READY"
check "probe postgres healthy" "$(probe postgres)" "healthy/READY"
check "probe keycloak exited" "$(probe keycloak)" "exited/FAIL"
check "probe redis unhealthy" "$(probe redis)"    "unhealthy/FAIL"
check "probe mysql absent"    "$(probe mysql)"    "absent/ABSENT"

# (The su_* probe mocks above are intentionally left in place — no test below
#  invokes them; the integrity section uses only pure expansion helpers.)

# ===========================================================================
section "INTEGRITY — vs the real repo"
# ---------------------------------------------------------------------------
# Every seam targets a script that actually exists.
missing=0
for s in preflight.sh mem-budget.sh startup.sh shutdown.sh health-monitor.sh status.sh check-secrets.sh; do
  [[ -f "${PROJECT_ROOT}/scripts/${s}" ]] || { _fail "seam target missing: scripts/${s}"; missing=1; tests_run=$((tests_run+1)); }
done
tests_run=$((tests_run+1)); (( missing == 0 )) && _pass "every seam targets an existing script"

# The dispatcher + status + lib all parse cleanly.
for f in scripts/pi scripts/status.sh scripts/lib/ctl-lib.sh; do
  tests_run=$((tests_run+1))
  if bash -n "${PROJECT_ROOT}/${f}" 2>/dev/null; then _pass "syntax ok: ${f}"; else _fail "syntax error: ${f}"; fi
done

# The real boot-profiles.conf resolves "core" to the expected component scope.
if [[ -f "${REAL_CONF}" ]]; then
  check "real core scope" "$(ctl_preflight_components "${REAL_CONF}" core | paste -sd' ' -)" "proxy management dashboard"
else
  _skip "real boot-profiles.conf scope (file unavailable)"
fi

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
