# shellcheck shell=bash
# ===========================================================================
# pi-system — UNIFIED CONTROL library  (pure logic + mockable seams)
# ---------------------------------------------------------------------------
# SOURCED by scripts/pi (the operator dispatcher), scripts/status.sh (the
# whole-system snapshot) and the test harness in tests/ctl/. It is the "control
# layer" that ORCHESTRATES the existing tools — it does NOT re-implement any of
# them. It mirrors scripts/lib/{preflight,mem-budget,startup,health-monitor}-lib.sh
# in spirit:
#
#   1. PURE functions — subcommand ROUTING, the `up`/`check` step ORDER, the
#      halt-on-first-failure SEQUENCING driver, scope resolution (profile ->
#      preflight components, reusing startup-lib), flag detection / pass-through,
#      and the status LABEL / VERDICT / overall ROLL-UP logic. They take their
#      inputs as arguments / stdin, so the tests verify every decision WITHOUT
#      Docker or a real Pi.
#
#   2. SEAM functions — thin wrappers around the ONLY external calls: invoking
#      each underlying script (preflight, mem-budget, startup, shutdown,
#      health-monitor, status). The dispatcher calls ONLY these to do real work;
#      a test redefines any of them to record the call order / inject a result,
#      which is exactly how "`up` runs preflight -> mem-budget -> startup and
#      halts if an earlier step fails" is proven without Docker.
#
# DESIGN RULES (kept identical to the sibling libs so they all feel the same):
#   * NO `set -e` here — this is a library; the entrypoint owns shell options.
#   * Classifier/decision functions print their result to stdout and `return 0`,
#     so a caller's `set -e` is never tripped by a verdict that happens to be a
#     "bad" one (DEGRADED / FAIL).
#   * THIN ORCHESTRATION ONLY: the seams shell out to the existing scripts; the
#     real readiness/budget/bring-up/health logic stays in those scripts and
#     their own libraries. Nothing here pulls an image, writes a secret, starts
#     or stops a container, or deletes a volume.
#   * Reuse startup-lib's registry + probe logic for status — never duplicate it.
# ===========================================================================

# Guard against double-sourcing (an entrypoint and the tests may both source it).
if [[ -n "${CTL_LIB_SOURCED:-}" ]]; then return 0 2>/dev/null || true; fi
CTL_LIB_SOURCED=1

# --- Resolve our own location + the project root ---------------------------
CTL_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${CTL_PROJECT_ROOT:=$(cd "${CTL_LIB_DIR}/../.." && pwd)}"

# Reuse the staged-bring-up library: its STAGE registry, the per-container probe
# logic (su_inspect / su_parse_inspect / su_probe_verdict), profile expansion
# (su_expand_tokens) and the service->preflight-component map. status.sh probes
# live containers through these SAME seams the bring-up uses, so the two can
# never describe the platform differently.
if [[ -f "${CTL_LIB_DIR}/startup-lib.sh" ]]; then
  : "${SU_PROJECT_ROOT:=${CTL_PROJECT_ROOT}}"; export SU_PROJECT_ROOT
  # shellcheck source=scripts/lib/startup-lib.sh
  source "${CTL_LIB_DIR}/startup-lib.sh"
fi

# The boot-profiles file is the single source of truth for profile -> members.
: "${CTL_PROFILE_CONF:=${CTL_PROJECT_ROOT}/infrastructure/boot-profiles.conf}"

# Shared scratch state (declared so `set -u` callers can read them when empty).
declare -a CTL_PF_ARGS=() CTL_MB_ARGS=() CTL_SU_ARGS=()
declare -a CTL_RESULTS=()   # "step<TAB>PASS|FAIL" accumulated by the oracle
declare -a CTL_EXECUTED=()  # steps actually run by ctl_run_sequence (test surface)

# ===========================================================================
# SECTION 1 — Subcommand ROUTING (pure)
# ===========================================================================
# Map the first CLI token to a canonical subcommand name. Unknown -> "unknown";
# no token / help flags -> "help". Keeping this pure lets the tests assert the
# routing table without running anything.
ctl_route() {
  case "${1:-}" in
    up)                 echo "up" ;;
    down)               echo "down" ;;
    status)             echo "status" ;;
    check)              echo "check" ;;
    health)             echo "health" ;;
    doctor|runbook)     echo "doctor" ;;
    help|-h|--help|"")  echo "help" ;;
    *)                  echo "unknown" ;;
  esac
}

# ===========================================================================
# SECTION 2 — Flag detection / pass-through (pure)
# ===========================================================================

# Is an exact flag present anywhere in the args?  ctl_has_flag --dry-run "$@"
ctl_has_flag() {
  local want="$1"; shift
  local a
  for a in "$@"; do [[ "${a}" == "${want}" ]] && return 0; done
  return 1
}

# Echo the value of --NAME (supports "--name val" and "--name=val"); returns 1
# (echoes nothing) if absent.  ctl_value_flag --ram "$@"
ctl_value_flag() {
  local want="$1"; shift
  local -a argv=("$@"); local i a
  for (( i=0; i<${#argv[@]}; i++ )); do
    a="${argv[$i]}"
    case "${a}" in
      "${want}")    i=$((i+1)); [[ ${i} -lt ${#argv[@]} ]] && { printf '%s' "${argv[$i]}"; return 0; } ;;
      "${want}="*)  printf '%s' "${a#*=}"; return 0 ;;
    esac
  done
  return 1
}

# Decode the "skip" flags into three 0/1 fields: "<dry> <skip_preflight>
# <skip_mem_budget>".  --skip-checks means skip BOTH; --dry-run skips both
# read-only gates too (a dry run starts nothing, so there is nothing to gate).
ctl_skip_flags() {
  local dry=0 pf=0 mb=0 a
  for a in "$@"; do
    case "${a}" in
      --dry-run)          dry=1 ;;
      --skip-checks)      pf=1; mb=1 ;;
      --skip-preflight)   pf=1 ;;
      --skip-mem-budget)  mb=1 ;;
    esac
  done
  printf '%s %s %s' "${dry}" "${pf}" "${mb}"
}

# Extract the boot-profile / service scope tokens from the args (the values of
# --profile and --services, comma- or space-separated). One token per line.
ctl_scope_tokens() {
  local -a argv=("$@") out=() _t; local i a s
  for (( i=0; i<${#argv[@]}; i++ )); do
    a="${argv[$i]}"
    case "${a}" in
      --profile)    i=$((i+1)); [[ ${i} -lt ${#argv[@]} ]] && out+=("${argv[$i]}") ;;
      --profile=*)  out+=("${a#*=}") ;;
      --services)   i=$((i+1)); [[ ${i} -lt ${#argv[@]} ]] && { s="${argv[$i]//,/ }"; read -r -a _t <<< "${s}"; out+=("${_t[@]}"); } ;;
      --services=*) s="${a#*=}"; s="${s//,/ }"; read -r -a _t <<< "${s}"; out+=("${_t[@]}") ;;
    esac
  done
  (( ${#out[@]} )) && printf '%s\n' "${out[@]}"
}

# The argv to forward to startup.sh: every original `up` arg PLUS --skip-checks
# (the dispatcher has ALREADY run the read-only gates, so startup must not run
# them a second time). One arg per line so the caller can mapfile it safely.
ctl_forward_startup_args() {
  printf '%s\n' "$@" "--skip-checks"
}

# ===========================================================================
# SECTION 3 — Scope resolution (pure; reuses startup-lib)
# ===========================================================================
# Expand profile/service tokens (via the SAME flattener bring-up uses) into the
# de-duplicated list of preflight COMPONENTS to scope preflight.sh to, so the
# checks cover exactly what `up` will start — no more, no less. label=MiB
# planning literals and unknown members are ignored. PURE given the conf file.
ctl_preflight_components() {
  local conf="$1"; shift
  {
    local svc comp
    for svc in $(su_expand_tokens "${conf}" "$@"); do
      [[ -n "${svc}" ]] || continue
      [[ "${svc}" == *=* ]] && continue
      comp="$(su_preflight_component "${svc}")"
      [[ -n "${comp}" ]] && echo "${comp}"
    done
  } | su_dedup_keep_order
}

# ===========================================================================
# SECTION 4 — SEQUENCING (pure driver + step planners)
# ===========================================================================

# The ordered steps for `up`: preflight -> mem-budget -> startup. Read-only gates
# are dropped when skipped (or on a dry run); startup always runs last. This is
# the canonical go-live order, isolated so the test can assert it directly.
#   args: <dry> <skip_preflight> <skip_mem_budget>
ctl_up_steps() {
  local dry="$1" pf="$2" mb="$3"; local -a s=()
  if [[ "${dry}" != "1" ]]; then
    [[ "${pf}" == "1" ]] || s+=("preflight")
    [[ "${mb}" == "1" ]] || s+=("mem-budget")
  fi
  s+=("startup")
  printf '%s\n' "${s[@]}"
}

# The ordered steps for `check`: the read-only pair only (no bring-up).
#   args: <skip_preflight> <skip_mem_budget>
ctl_check_steps() {
  local pf="$1" mb="$2"; local -a s=()
  [[ "${pf}" == "1" ]] || s+=("preflight")
  [[ "${mb}" == "1" ]] || s+=("mem-budget")
  (( ${#s[@]} )) && printf '%s\n' "${s[@]}"
}

# Walk the given steps in order, calling ORACLE for each, and HALT the moment one
# fails — so a later step never runs once an earlier one breaks. Records every
# step it actually ran in CTL_EXECUTED. Returns 0 if all passed, 1 otherwise.
# (The exact shape of startup-lib's su_run_plan, reused here for the higher-level
# preflight->mem-budget->startup sequence. PURE given a pure oracle; the live
# oracle is ctl_step_run, the test drives it with a mocked oracle AND with the
# real ctl_step_run over mocked seams.)
ctl_run_sequence() {
  local oracle="$1"; shift
  local step rc=0
  CTL_EXECUTED=()
  for step in "$@"; do
    CTL_EXECUTED+=("${step}")
    if ! "${oracle}" "${step}"; then rc=1; break; fi
  done
  return "${rc}"
}

# The live ORACLE: run ONE step by delegating to the matching seam, record its
# PASS/FAIL in CTL_RESULTS, and return the seam's exit code (so ctl_run_sequence
# can halt). It reads the per-tool argv the dispatcher prepared in CTL_PF_ARGS /
# CTL_MB_ARGS / CTL_SU_ARGS. Silent by design — each underlying tool prints its
# own rich report; the dispatcher prints the aggregated summary from CTL_RESULTS.
ctl_step_run() {
  local step="$1" rc=0
  case "${step}" in
    preflight)  if ctl_run_preflight  "${CTL_PF_ARGS[@]}"; then rc=0; else rc=$?; fi ;;
    mem-budget) if ctl_run_mem_budget "${CTL_MB_ARGS[@]}"; then rc=0; else rc=$?; fi ;;
    startup)    if ctl_run_startup    "${CTL_SU_ARGS[@]}"; then rc=0; else rc=$?; fi ;;
    *)          rc=2 ;;
  esac
  if (( rc == 0 )); then CTL_RESULTS+=("${step}"$'\t'"PASS"); else CTL_RESULTS+=("${step}"$'\t'"FAIL"); fi
  return "${rc}"
}

# A human label for a step (for the aggregated report).
ctl_step_desc() {
  case "$1" in
    preflight)  echo "host readiness (read-only)" ;;
    mem-budget) echo "memory budget (read-only)" ;;
    startup)    echo "staged, verified bring-up" ;;
    *)          echo "$1" ;;
  esac
}

# ===========================================================================
# SECTION 5 — STATUS aggregation / verdict (pure; reuses startup-lib probes)
# ===========================================================================

# A human STATUS LABEL for one container from its inspect fields. Distinct from
# the READY/WAIT/FAIL verdict (su_probe_verdict): the label is what the operator
# reads, the verdict is what the roll-up counts. "absent" = no container exists.
#   args: <health> <state> <restarting>
ctl_status_label() {
  local health="$1" state="$2" restarting="$3"
  if [[ -n "${health}" && "${health}" != "none" ]]; then
    case "${health}" in
      healthy)   echo "healthy" ;;
      unhealthy) echo "unhealthy" ;;
      starting)  echo "starting" ;;
      *)         echo "${health}" ;;
    esac
    return 0
  fi
  case "${state}" in
    running)    [[ "${restarting}" == "true" ]] && echo "restarting" || echo "running" ;;
    created)    echo "starting" ;;
    restarting) echo "restarting" ;;
    paused)     echo "paused" ;;
    exited)     echo "exited" ;;
    dead)       echo "dead" ;;
    ""|removing) echo "absent" ;;
    *)          echo "${state:-absent}" ;;
  esac
}

# Probe ONE service: resolve its container (read-only) and classify it. Echoes a
# single TAB-separated line "<label>\t<verdict>" where verdict is READY / WAIT /
# FAIL / ABSENT. A snapshot can't measure restart GROWTH, so the crash-loop guard
# is disabled here (threshold 0, baseline=current). Goes through the SAME seams
# the bring-up uses, so a test mocks su_service_container_id + su_inspect.
#   args: <service> <compose-argv...>
ctl_probe_service() {
  local svc="$1"; shift
  local id; id="$(su_service_container_id "${svc}" "$@")"
  if [[ -z "${id}" ]]; then printf '%s\t%s' "absent" "ABSENT"; return 0; fi
  local parsed state restarting count health
  parsed="$(su_parse_inspect "$(su_inspect "${id}")")"
  IFS=$'\t' read -r state restarting count health <<< "${parsed}"
  local verdict label
  verdict="$(su_probe_verdict "${health}" "${state}" "${restarting}" "${count}" "${count}" 0)"
  label="$(ctl_status_label "${health}" "${state}" "${restarting}")"
  printf '%s\t%s' "${label}" "${verdict}"
}

# Extract the host-health verdict word (PASS|WARN|FAIL) from a captured run of
# health-monitor.sh; UNKNOWN if not found. Pure string parsing (no Docker).
ctl_health_verdict() {
  local v
  v="$(printf '%s\n' "$1" | grep -oE 'VERDICT: (PASS|WARN|FAIL)' | head -n1 | awk '{print $2}' || true)"
  printf '%s' "${v:-UNKNOWN}"
}

# Roll many signals into ONE overall verdict for the snapshot:
#   * any RUNNING container that is broken (exited/unhealthy/crash-looped) -> DEGRADED
#   * host health hard-FAIL                                               -> DEGRADED
#   * nothing running at all                                              -> DOWN
#   * otherwise                                                           -> UP
#   args: <broken_count> <up_count> <host_verdict>
ctl_status_overall() {
  local broken="${1:-0}" up="${2:-0}" host="${3:-UNKNOWN}"
  if (( broken > 0 ));            then echo "DEGRADED"; return 0; fi
  if [[ "${host}" == "FAIL" ]];   then echo "DEGRADED"; return 0; fi
  if (( up == 0 ));               then echo "DOWN";     return 0; fi
  echo "UP"
}

# Fold one service verdict into the running tallies. Echoes the updated
# "<broken> <up> <off> <waiting>" given the previous tallies + a verdict. Keeps
# the counting rule in one tested place:
#   FAIL  -> broken (it exists and is bad)        READY -> up
#   WAIT  -> up + waiting (exists, still settling) ABSENT -> off (intentionally not running)
ctl_status_tally() {
  local broken="$1" up="$2" off="$3" waiting="$4" verdict="$5"
  case "${verdict}" in
    FAIL)   broken=$((broken+1)) ;;
    READY)  up=$((up+1)) ;;
    WAIT)   up=$((up+1)); waiting=$((waiting+1)) ;;
    ABSENT) off=$((off+1)) ;;
  esac
  printf '%s %s %s %s' "${broken}" "${up}" "${off}" "${waiting}"
}

# ===========================================================================
# SECTION 6 — DOCTOR: the next recommended command (pure)
# ===========================================================================
# Powers `pi doctor` — a thin bridge into the first-run RUNBOOK. Given three
# READ-ONLY signals about the host, it decides the SINGLE next command the
# operator should run and points at the matching RUNBOOK step. It is PURE: the
# dispatcher gathers the signals through the existing seams (an `.env` test,
# check-secrets.sh, status.sh) and passes them in, so every branch is unit-tested
# WITHOUT Docker or a real Pi. It NEVER starts anything — it only recommends.
# Echoes "<command>\t<reason>". The order mirrors the RUNBOOK's own order:
# bootstrap (C) -> secrets (C) -> readiness/bring-up (D-E) -> stay healthy (J-K).
#   args: <env_exists 0|1> <secrets_ok 0|1> <status_verdict UP|DOWN|DEGRADED|UNKNOWN>
ctl_next_command() {
  local env_exists="$1" secrets_ok="$2" verdict="$3"
  if [[ "${env_exists}" != "1" ]]; then
    printf '%s\t%s' "./scripts/setup.sh" \
      "no .env yet — bootstrap the project, then generate secrets (RUNBOOK step C)"
    return 0
  fi
  if [[ "${secrets_ok}" != "1" ]]; then
    printf '%s\t%s' "./scripts/check-secrets.sh" \
      "secrets are missing or weak — generate & fill them, then re-audit (RUNBOOK step C)"
    return 0
  fi
  case "${verdict}" in
    DEGRADED) printf '%s\t%s' "./scripts/pi status" \
      "something running is broken — inspect it, then re-run scripts/pi up (RUNBOOK step E / Troubleshooting)" ;;
    UP)       printf '%s\t%s' "./scripts/pi status" \
      "core is up — keep it healthy: schedule backups and the health-monitor cron (RUNBOOK steps J-K)" ;;
    DOWN)     printf '%s\t%s' "./scripts/pi up --profile core" \
      "host is ready and nothing is running — bring the verified core up (RUNBOOK steps D-E)" ;;
    *)        printf '%s\t%s' "./scripts/pi check --profile core" \
      "live state could not be read here — run on the Pi to verify readiness (RUNBOOK step D)" ;;
  esac
}

# Extract the whole-system verdict word from a captured status.sh run; UNKNOWN
# if absent. Pure string parsing (mirrors ctl_health_verdict), so a test feeds it
# canned output with no Docker.
ctl_status_verdict_word() {
  local v
  v="$(printf '%s\n' "$1" | grep -oE 'VERDICT: (UP|DOWN|DEGRADED|UNKNOWN)' | head -n1 | awk '{print $2}' || true)"
  printf '%s' "${v:-UNKNOWN}"
}

# ===========================================================================
# SECTION 7 — SEAMS (every external call: invoking an existing script). The
#             dispatcher/status call ONLY these; a test redefines any of them.
#             Defaults shell out to the real, already-tested scripts.
# ===========================================================================
ctl_run_preflight()  { bash "${CTL_PROJECT_ROOT}/scripts/preflight.sh"      "$@"; }
ctl_run_mem_budget() { bash "${CTL_PROJECT_ROOT}/scripts/mem-budget.sh"     "$@"; }
ctl_run_startup()    { bash "${CTL_PROJECT_ROOT}/scripts/startup.sh"        "$@"; }
ctl_run_shutdown()   { bash "${CTL_PROJECT_ROOT}/scripts/shutdown.sh"       "$@"; }
ctl_run_health()     { bash "${CTL_PROJECT_ROOT}/scripts/health-monitor.sh" "$@"; }
ctl_run_status()     { bash "${CTL_PROJECT_ROOT}/scripts/status.sh"         "$@"; }
ctl_run_check_secrets() { bash "${CTL_PROJECT_ROOT}/scripts/check-secrets.sh" "$@"; }
