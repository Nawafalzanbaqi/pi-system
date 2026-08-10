#!/usr/bin/env bash
# ===========================================================================
# pi-system — staged bring-up TEST HARNESS
# ---------------------------------------------------------------------------
# Exercises the PURE decision logic of scripts/startup.sh + scripts/shutdown.sh
# (via the sourced library scripts/lib/startup-lib.sh) against FIXTURES and
# MOCKED seams, so the staging is verified WITHOUT Docker or a real Pi —
# mirroring tests/preflight/run.sh and tests/mem-budget/run.sh.
#
# Coverage (each maps to a real way staged bring-up could go wrong):
#   * stage ORDER + dependency correctness -> SU_STAGE_ORDER positions, registry
#   * registry integrity vs the REAL repo  -> every stage's compose files exist;
#                                             services <-> stages are consistent
#   * verify decision logic                -> su_probe_verdict across healthy /
#                                             unhealthy / starting / no-healthcheck
#                                             (distroless fallback) / crash-loop
#   * fold many containers -> one stage     -> su_worst / su_fold_verdicts
#   * inspect-line parsing                  -> su_parse_inspect (incl. empty)
#   * retry BACKOFF + TIMEOUT               -> su_backoff_delay / su_deadline_reached
#   * profile -> stages expansion           -> su_plan_from_services, su_expand_tokens
#                                             (+ cycle guard) against the fixture conf
#   * compose PROFILE flags per service     -> su_profiles_for_services
#   * a failed stage HALTS the rest         -> su_run_plan with a mocked oracle
#   * the REAL boot-profiles.conf           -> every member maps to a known stage
#
# Usage:   ./tests/startup/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${PROJECT_ROOT}/scripts/lib/startup-lib.sh"
FIX="${SCRIPT_DIR}/fixtures"
REAL_CONF="${PROJECT_ROOT}/infrastructure/boot-profiles.conf"

if [[ ! -f "${LIB}" ]]; then
  printf 'FATAL: library not found: %s\n' "${LIB}" >&2
  exit 2
fi
export SU_PROJECT_ROOT="${PROJECT_ROOT}"
# shellcheck source=../../scripts/lib/startup-lib.sh
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
# check_lt NAME A B   (assert integer A < B)
check_lt() {
  tests_run=$((tests_run+1))
  if (( $2 < $3 )); then _pass "$1"; else _fail "$1 — expected $2 < $3"; fi
}

# Index of a stage within SU_STAGE_ORDER (or -1).
idx() { local s="$1" i; for i in "${!SU_STAGE_ORDER[@]}"; do [[ "${SU_STAGE_ORDER[$i]}" == "${s}" ]] && { echo "${i}"; return; }; done; echo "-1"; }
# The selected services for STAGE from a su_plan_from_services run of "$@".
plan_line() { local stage="$1"; shift; su_plan_from_services "$@" | awk -F'\t' -v s="${stage}" '$1==s{print $2}'; }
# Expand tokens via the FIXTURE conf, then plan -> selected services for STAGE.
expand_line() { local stage="$1" conf="$2"; shift 2; su_plan_from_services $(su_expand_tokens "${conf}" "$@") | awk -F'\t' -v s="${stage}" '$1==s{print $2}'; }

# ===========================================================================
section "ORDER — stage order & dependency correctness (pure)"
# ---------------------------------------------------------------------------
check "first stage is networks" "${SU_STAGE_ORDER[0]}" "networks"
check "last stage is projects"  "${SU_STAGE_ORDER[-1]}" "projects"
check_lt "proxy before management"     "$(idx proxy)"      "$(idx management)"
check_lt "management before dashboard" "$(idx management)" "$(idx dashboard)"
check_lt "dashboard before databases"  "$(idx dashboard)"  "$(idx databases)"
check_lt "databases before db-admin"   "$(idx databases)"  "$(idx db-admin)"
check_lt "databases before auth"       "$(idx databases)"  "$(idx auth)"
check_lt "auth before automation"      "$(idx auth)"       "$(idx automation)"
check_lt "automation before projects"  "$(idx automation)" "$(idx projects)"

# su_order_stages: arbitrary set -> canonical order, de-duplicated.
check "order_stages dedups + orders" \
  "$(printf '%s\n' automation networks proxy automation | su_order_stages | paste -sd' ' -)" \
  "networks proxy automation"
tests_run=$((tests_run+1)); su_is_stage databases && _pass "is_stage: databases known" || _fail "is_stage: databases should be known"
tests_run=$((tests_run+1)); su_is_stage bogus && _fail "is_stage: bogus should be unknown" || _pass "is_stage: bogus rejected"

# ===========================================================================
section "REGISTRY — stage map vs the REAL repo (integrity)"
# ---------------------------------------------------------------------------
# Every ordered stage has a description and compose entry.
missing=0
for st in "${SU_STAGE_ORDER[@]}"; do
  [[ -n "${SU_STAGE_DESC[${st}]:-}" ]]    || { _fail "registry: stage '${st}' has no description"; missing=1; tests_run=$((tests_run+1)); }
  [[ -n "${SU_STAGE_COMPOSE[${st}]:-}" ]] || { _fail "registry: stage '${st}' has no compose entry"; missing=1; tests_run=$((tests_run+1)); }
done
tests_run=$((tests_run+1)); (( missing == 0 )) && _pass "registry: every stage has desc + compose"

# Every compose file referenced by the registry actually exists.
missing=0
for st in "${SU_STAGE_ORDER[@]}"; do
  for f in ${SU_STAGE_COMPOSE[${st}]}; do
    [[ -f "${PROJECT_ROOT}/${f}" ]] || { _fail "registry: stage ${st} references missing file ${f}"; missing=1; tests_run=$((tests_run+1)); }
  done
done
tests_run=$((tests_run+1)); (( missing == 0 )) && _pass "registry: all referenced compose files exist"

# Each member service maps BACK to the stage that lists it (no drift).
drift=0
for st in "${SU_STAGE_ORDER[@]}"; do
  for svc in ${SU_STAGE_SERVICES[${st}]:-}; do
    [[ "$(su_service_stage "${svc}")" == "${st}" ]] || { _fail "registry: ${svc} (stage ${st}) maps to '$(su_service_stage "${svc}")'"; drift=1; tests_run=$((tests_run+1)); }
  done
done
tests_run=$((tests_run+1)); (( drift == 0 )) && _pass "registry: service<->stage mapping is consistent"

# Every keyed Compose profile belongs to a real member service.
badp=0
all_services=" "; for st in "${SU_STAGE_ORDER[@]}"; do all_services+="${SU_STAGE_SERVICES[${st}]:-} "; done
for svc in "${!SU_SERVICE_PROFILE[@]}"; do
  [[ "${all_services}" == *" ${svc} "* ]] || { _fail "registry: profile keyed for unknown service '${svc}'"; badp=1; tests_run=$((tests_run+1)); }
done
tests_run=$((tests_run+1)); (( badp == 0 )) && _pass "registry: every profiled service is a known member"

# preflight-component mapping covers every real member with a valid component.
valid_components=" proxy management dashboard postgres mysql mongo redis pgadmin adminer mongo-express cache auth automation "
badc=0
for st in proxy management dashboard databases db-admin cache auth automation; do
  for svc in ${SU_STAGE_SERVICES[${st}]:-}; do
    comp="$(su_preflight_component "${svc}")"
    [[ "${valid_components}" == *" ${comp} "* ]] || { _fail "preflight map: ${svc} -> '${comp}' (not a preflight component)"; badc=1; tests_run=$((tests_run+1)); }
  done
done
tests_run=$((tests_run+1)); (( badc == 0 )) && _pass "preflight map: every member -> a valid preflight component"

# ===========================================================================
section "VERIFY — per-container probe verdict (pure)"
# ---------------------------------------------------------------------------
# With a healthcheck: trust Docker's health.
check "hc healthy   -> READY" "$(su_probe_verdict healthy   running false 0 0 3)" "READY"
check "hc unhealthy -> FAIL"  "$(su_probe_verdict unhealthy running false 0 0 3)" "FAIL"
check "hc starting  -> WAIT"  "$(su_probe_verdict starting  running false 0 0 3)" "WAIT"
# No healthcheck (distroless fallback): use the lifecycle state.
check "no-hc running        -> READY" "$(su_probe_verdict none running    false 0 0 3)" "READY"
check "no-hc running+restart-> WAIT"  "$(su_probe_verdict none running    true  0 0 3)" "WAIT"
check "no-hc created        -> WAIT"  "$(su_probe_verdict none created    false 0 0 3)" "WAIT"
check "no-hc not-created    -> WAIT"  "$(su_probe_verdict none ''         false 0 0 3)" "WAIT"
check "no-hc exited         -> FAIL"  "$(su_probe_verdict none exited     false 0 0 3)" "FAIL"
check "no-hc dead           -> FAIL"  "$(su_probe_verdict none dead       false 0 0 3)" "FAIL"
check "no-hc paused         -> FAIL"  "$(su_probe_verdict none paused     false 0 0 3)" "FAIL"
# Crash-loop guard (restart count grew by >= threshold since baseline).
check "crash-loop no-hc running -> FAIL"  "$(su_probe_verdict none     running false 5 0 3)" "FAIL"
check "crash-loop while starting -> FAIL" "$(su_probe_verdict starting running false 5 0 3)" "FAIL"
check "healthy NOW beats restart history" "$(su_probe_verdict healthy  running false 9 0 3)" "READY"
check "delta below threshold -> READY"    "$(su_probe_verdict none     running false 2 0 3)" "READY"
check "threshold 0 disables guard"        "$(su_probe_verdict none     running false 9 0 0)" "READY"

# Inspect-line parsing (the seam output -> probe args).
check "parse: full line"  "$(su_parse_inspect $'running\tfalse\t2\thealthy' | tr '\t' '|')" "running|false|2|healthy"
check "parse: empty -> defaults" "$(su_parse_inspect '' | tr '\t' '|')" "|false|0|none"

# ===========================================================================
section "FOLD — many container verdicts -> one stage verdict (pure)"
# ---------------------------------------------------------------------------
check "worst READY,WAIT -> WAIT" "$(su_worst READY WAIT)" "WAIT"
check "worst WAIT,FAIL  -> FAIL" "$(su_worst WAIT FAIL)"  "FAIL"
check "worst READY,READY-> READY" "$(su_worst READY READY)" "READY"
check "fold all-ready -> READY" "$(printf '%s\n' READY READY | su_fold_verdicts)" "READY"
check "fold any-wait  -> WAIT"  "$(printf '%s\n' READY WAIT READY | su_fold_verdicts)" "WAIT"
check "fold any-fail  -> FAIL"  "$(printf '%s\n' READY WAIT FAIL | su_fold_verdicts)" "FAIL"
check "fold empty     -> READY" "$(printf '' | su_fold_verdicts)" "READY"

# ===========================================================================
section "RETRY — backoff + timeout decision (pure)"
# ---------------------------------------------------------------------------
check "backoff a1 (base 3, cap 15)" "$(su_backoff_delay 1 3 15)" "3"
check "backoff a2"                   "$(su_backoff_delay 2 3 15)" "6"
check "backoff a3"                   "$(su_backoff_delay 3 3 15)" "12"
check "backoff a4 capped"            "$(su_backoff_delay 4 3 15)" "15"
check "backoff a5 stays at cap"      "$(su_backoff_delay 5 3 15)" "15"
check "backoff base 2, a4 -> 15 cap" "$(su_backoff_delay 4 2 15)" "15"
check "deadline 0/120  -> no"  "$(su_deadline_reached 0 120)"   "no"
check "deadline 120/120-> yes" "$(su_deadline_reached 120 120)" "yes"
check "deadline 130/120-> yes" "$(su_deadline_reached 130 120)" "yes"

# ===========================================================================
section "PLAN — profile/services -> ordered stage plan (pure)"
# ---------------------------------------------------------------------------
check "plan: proxy from caddy"        "$(plan_line proxy caddy postgres)"     "caddy"
check "plan: databases from postgres" "$(plan_line databases caddy postgres)" "postgres"
check "plan: management group"        "$(plan_line management caddy portainer uptime-kuma watchtower homepage)" "portainer uptime-kuma watchtower"
check "plan: dashboard from homepage" "$(plan_line dashboard homepage)"       "homepage"
check "plan: literal allowance skipped" "$(plan_line proxy caddy app-x=512)"  "caddy"
check "plan: unknown member skipped"    "$(su_plan_from_services bogus | wc -l | tr -d ' ')" "0"
# Output order follows SU_STAGE_ORDER regardless of input order.
check "plan: emitted in stage order" \
  "$(su_plan_from_services postgres caddy homepage | cut -f1 | paste -sd' ' -)" \
  "proxy dashboard databases"

# ===========================================================================
section "EXPAND — boot profile -> stages, via the fixture conf (pure)"
# ---------------------------------------------------------------------------
check "core: proxy=caddy"          "$(expand_line proxy "${FIX}/profiles.conf" core)"      "caddy"
check "core: management trio"      "$(expand_line management "${FIX}/profiles.conf" core)" "portainer uptime-kuma watchtower"
check "core: dashboard"            "$(expand_line dashboard "${FIX}/profiles.conf" core)"  "homepage"
check "core: NO databases"         "$(expand_line databases "${FIX}/profiles.conf" core)"  ""
check "dev: databases=postgres"    "$(expand_line databases "${FIX}/profiles.conf" dev)"   "postgres"
check "dev: cache pair"            "$(expand_line cache "${FIX}/profiles.conf" dev)"        "verdaccio nuget-cache"
check "auth: auth members"         "$(expand_line auth "${FIX}/profiles.conf" auth)"        "keycloak keycloak-db"
check "automation: members"        "$(expand_line automation "${FIX}/profiles.conf" automation)" "n8n n8n-db"
check "mixed: two db engines"      "$(expand_line databases "${FIX}/profiles.conf" mixed)"  "postgres mysql"
check "mixed: db-admin selected"   "$(expand_line db-admin "${FIX}/profiles.conf" mixed)"   "pgadmin"
# Cycle guard: ring1 <-> ring2 must terminate and still resolve its members.
check "cycle ring1 -> proxy=caddy"     "$(expand_line proxy "${FIX}/profiles.conf" ring1)"     "caddy"
check "cycle ring1 -> databases=postgres" "$(expand_line databases "${FIX}/profiles.conf" ring1)" "postgres"

# Compose PROFILE flags derived from selected services.
check "profiles: db engines"   "$(su_profiles_for_services postgres redis | paste -sd' ' -)" "postgres redis"
check "profiles: cache dedup"  "$(su_profiles_for_services verdaccio nuget-cache | paste -sd' ' -)" "cache"
check "profiles: none needed"  "$(su_profiles_for_services caddy homepage | paste -sd' ' -)" ""

# ===========================================================================
section "HALT — a failed stage stops the rest (su_run_plan, mocked oracle)"
# ---------------------------------------------------------------------------
FAIL_AT=""
mock_oracle() { [[ -n "${FAIL_AT}" && "$1" == "${FAIL_AT}" ]] && return 1 || return 0; }

# All healthy: every stage runs, overall success.
FAIL_AT=""
su_run_plan mock_oracle networks proxy management dashboard; rc=$?
check "all healthy -> rc 0"          "${rc}" "0"
check "all healthy -> ran every stage" "$(printf '%s ' "${SU_EXECUTED[@]}")" "networks proxy management dashboard "

# Management fails: dashboard/databases never start.
FAIL_AT="management"
su_run_plan mock_oracle networks proxy management dashboard databases; rc=$?
check "mgmt fails -> rc 1"           "${rc}" "1"
check "mgmt fails -> halts at mgmt"  "$(printf '%s ' "${SU_EXECUTED[@]}")" "networks proxy management "

# First stage fails: nothing after it runs.
FAIL_AT="networks"
su_run_plan mock_oracle networks proxy management; rc=$?
check "networks fails -> only networks ran" "$(printf '%s ' "${SU_EXECUTED[@]}")" "networks "

# ===========================================================================
section "PROJECTS — discovery distinguishes generated apps from platform dirs"
# ---------------------------------------------------------------------------
# acme-portal carries the new-project.sh marker; proxy/notaproject do not, so
# only the real generated project is discovered (the platform is NOT re-deployed).
check "discover: only the marked project" \
  "$(SU_SERVICES_DIR="${FIX}/services" su_discover_projects | paste -sd' ' -)" \
  "acme-portal"
# Against the REAL services/ tree there are currently no generated projects, so
# discovery must be empty (every dir there is a platform service without a marker).
check "discover: real services/ has no generated projects (yet)" \
  "$(su_discover_projects | paste -sd' ' -)" ""

# ===========================================================================
section "REAL — the actual boot-profiles.conf maps cleanly to stages"
# ---------------------------------------------------------------------------
if [[ -f "${REAL_CONF}" ]] && declare -F mb_flatten >/dev/null 2>&1; then
  orphans=""
  while IFS= read -r p; do
    [[ -n "${p}" ]] || continue
    while IFS= read -r m; do
      [[ -n "${m}" ]] || continue
      [[ "${m}" == *=* ]] && continue                 # planning literal — fine
      [[ -z "$(su_service_stage "${m}")" ]] && orphans+=" ${p}:${m}"
    done < <(mb_flatten "${REAL_CONF}" "${p}")
  done < <(mb_profile_names "${REAL_CONF}")
  check "real profiles: every service member owns a stage (no orphans)" "${orphans}" ""
else
  _skip "real boot-profiles.conf integrity (file or mb_flatten unavailable)"
fi

# Real compose files for every stage exist (tie the registry to the real tree).
missing=0
for st in "${SU_STAGE_ORDER[@]}"; do
  for f in ${SU_STAGE_COMPOSE[${st}]}; do [[ -f "${PROJECT_ROOT}/${f}" ]] || missing=1; done
done
tests_run=$((tests_run+1)); (( missing == 0 )) && _pass "real repo: all stage compose files present" || _fail "real repo: a stage compose file is missing"

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
