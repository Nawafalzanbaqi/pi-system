#!/usr/bin/env bash
# ===========================================================================
# pi-system — Telegram bot EXECUTION BRIDGE (the audited security boundary)
# ---------------------------------------------------------------------------
# n8n must NOT run arbitrary host commands. This script is the ONE, tightly
# scoped, auditable door between the Telegram management workflow and the host:
# it accepts ONLY a fixed set of named actions, validates every argument against
# an allowlist, LOGS every invocation, and maps each action to the existing
# operator tools (scripts/pi, scripts/status.sh, scripts/project.sh). It NEVER
# evals input and NEVER reimplements those tools — it orchestrates them.
#
#   ALLOWED ACTIONS (anything else is refused):
#     READ-ONLY (never change state):
#       status                 -> scripts/pi status        (whole-system snapshot)
#       health                 -> scripts/pi health        (host hardware health)
#       check                  -> scripts/pi check         (preflight + mem-budget)
#       projects               -> list generated projects + state (read-only)
#     STATE-CHANGING (whitelisted + logged):
#       up   [profile]         -> scripts/pi up   --profile <profile> -y   (default core)
#       down [profile]         -> scripts/pi down --profile <profile> -y   (default core)
#       project_up   <name>    -> scripts/project.sh up   <name>
#       project_down <name>    -> scripts/project.sh down <name>
#       restart <service>      -> scripts/<service-helper> down && up  (recreate)
#                                 service in: automation analytics auth dashboard
#                                 cache control-api (the Control API config-change
#                                 path; whitelisted via bot-lib BOT_VALID_SERVICE)
#       audit_url <url>        -> scripts/seo.sh audit bot-audit --url <url> --depth standard
#       panel_audit_url <url>  -> ... --depth deep   (multi-specialist panel)
#                                 URL is passed as a SINGLE argv element end-to-end (never
#                                 interpolated). Refused BEFORE Docker via the SSRF guard
#                                 (services/seo/engine/ssrf-check.js) — non-http(s)
#                                 scheme, credentials-in-URL, literal internal IP, or
#                                 internal hostname are rejected at the boundary. The
#                                 engine's probe re-checks every hop (DNS-rebinding).
#     READ-ONLY panel-data feeds (Control API Monitoring/Growth; never change state):
#       monitor_metrics        -> scripts/panel-read.sh monitor_metrics
#       monitor_alerts         -> scripts/panel-read.sh monitor_alerts
#       backup_status          -> scripts/panel-read.sh backup_status
#       seo_audits             -> scripts/panel-read.sh seo_audits
#       prospects_list         -> scripts/panel-read.sh prospects_list
#                                 (panel-read.sh ONLY reads the producers' status/
#                                  log/store files; no mutation, no Docker socket.)
#
# USAGE
#   scripts/bot-exec.sh <action> [argument]      # direct (operator / tests)
#   scripts/bot-exec.sh --from-ssh               # read $SSH_ORIGINAL_COMMAND
#   scripts/bot-exec.sh -h | --help
#
# HOW n8n CALLS IT SAFELY  (see docs/README.md "Telegram management bot")
#   n8n is containerized and is NOT given the Docker socket or the host
#   filesystem. The workflow reaches this script over SSH using a DEDICATED key,
#   sending only the already-validated "<action> <arg>" string. The recommended
#   hardening pins that key to a forced command in ~/.ssh/authorized_keys
#   (invoked via `bash`, so the script needs no execute bit):
#       command="bash /PATH/TO/pi-system/scripts/bot-exec.sh --from-ssh",no-pty,\
#       no-port-forwarding,no-X11-forwarding,no-agent-forwarding <key...>
#   so the key can ONLY ever launch THIS script; the requested action arrives in
#   $SSH_ORIGINAL_COMMAND, which --from-ssh tokenizes (read -ra, no eval) and
#   re-validates here. Whether invoked directly or via SSH, the validation below
#   is the real boundary — defence in depth.
#
# ENV KNOBS
#   BOT_EXEC_DRYRUN=1          validate + LOG + print the PLANned command, but do
#                              NOT execute it (used by tests; never touches Docker)
#   TELEGRAM_BOT_EXEC_LOG      audit log path (default: ./data/bot/bot-exec.log)
#   NO_COLOR is exported to the underlying tools so replies are plain text.
#
# Exit codes: 0 success; 2 = refused (unknown action / bad argument / usage);
# otherwise the underlying tool's exit code. Run from anywhere — paths resolve
# relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Load the pure decision logic (parser / whitelist / validation) --------
export BOT_PROJECT_ROOT="${PROJECT_ROOT}"
LIB="${SCRIPT_DIR}/lib/bot-lib.sh"
if [[ ! -f "${LIB}" ]]; then
  printf '[bot-exec][error] missing required library: %s\n' "${LIB}" >&2
  exit 2
fi
# shellcheck source=scripts/lib/bot-lib.sh
source "${LIB}"

# --- Audit log -------------------------------------------------------------
LOG_FILE="${TELEGRAM_BOT_EXEC_LOG:-${PROJECT_ROOT}/data/bot/bot-exec.log}"

# Timestamp seam (overridable in tests for determinism).
bot_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Append one tab-separated audit line. Best-effort: a log we cannot write must
# never crash the bridge, but we DO surface it on stderr.
bot_log() {
  local line="$1" dir
  dir="$(dirname "${LOG_FILE}")"
  mkdir -p "${dir}" 2>/dev/null || true
  if ! printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null; then
    printf '[bot-exec][warn] could not write audit log: %s\n' "${LOG_FILE}" >&2
  fi
}

log_event() {  # log_event <phase> <action> <arg> <class> <result>
  bot_log "$(bot_now)	$1	action=$2	arg=${3:-"-"}	class=$4	$5"
}

# --- Tiny stderr helpers ---------------------------------------------------
err()    { printf '[bot-exec][error] %s\n' "$*" >&2; }
refuse() { # refuse <action> <arg> <reason>
  err "refused: $3"
  log_event refused "${1:-?}" "${2:-}" "n/a" "result=REFUSED reason=$3"
  exit 2
}

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ===========================================================================
# Execution SEAMS — the only place real host commands run. Overridable so tests
# never touch Docker. Each orchestrates an existing tool; none is reimplemented.
# Plain text (NO_COLOR) so the output is Telegram-friendly.
# ===========================================================================
bot_run_pi()      { NO_COLOR=1 bash "${SCRIPT_DIR}/pi" "$@"; }
bot_run_project() { NO_COLOR=1 bash "${SCRIPT_DIR}/project.sh" "$@"; }

# Control API READ-ONLY panel-data feeds: one read-only door to the producers'
# status/log/store files. panel-read.sh only cats/tails data + a read-only docker
# stats snapshot; it never mutates. The subcommand is resolved from bot-lib's
# BOT_PANEL_READ map (validated before we get here).
bot_run_panel_read() { NO_COLOR=1 bash "${SCRIPT_DIR}/panel-read.sh" "$@"; }

# `audit_url` / `panel_audit_url`: SSRF-guarded ad-hoc audit of ONE operator-pasted
# URL. The URL is passed as a SINGLE argv element end-to-end — never interpolated.
# The bridge ALREADY refused if classifyUrl (the SSRF guard) called below blocks it;
# the SEO engine's probeUrl ALSO runs the full assertUrlAllowed (with DNS rebinding
# defence) when it actually fetches — defence in depth. The audit is stored under
# the fixed name `bot-audit` (the operator's append-only ad-hoc history).
bot_run_audit_url() {  # bot_run_audit_url <depth> <url>
  local depth="$1" url="$2"
  NO_COLOR=1 bash "${SCRIPT_DIR}/seo.sh" audit bot-audit --url "${url}" --depth "${depth}"
}

# Stage-1 SSRF check on a URL the operator pasted. Spawns node with the URL as a
# SINGLE argv element (execFile-style: $2 is one token, NEVER interpolated into a
# shell string). Returns 0 if classifyUrl approves, non-zero on any refusal. The
# helper writes the reason to stderr (non-leaky). Overridable in tests via
# BOT_SSRF_CHECK_CMD so the test harness can drive it without node, but the real
# binary is wired here and the test suite ALSO covers it directly.
bot_run_ssrf_check() {  # bot_run_ssrf_check <url>
  if [[ -n "${BOT_SSRF_CHECK_CMD:-}" ]]; then
    "${BOT_SSRF_CHECK_CMD}" "$1"
    return $?
  fi
  if ! command -v node >/dev/null 2>&1; then
    err "node not available; cannot run the SSRF stage-1 check"
    return 2
  fi
  node "${PROJECT_ROOT}/services/seo/engine/ssrf-check.js" "$1"
}

# `restart <service>`: recreate ONE allowlisted service via its OWN up/down helper
# (down then up — recreation, so a changed .env value is actually picked up). The
# service is validated against BOT_VALID_SERVICE before we get here; we resolve its
# helper from bot-lib. No new docker logic, no socket — just the existing helpers.
bot_run_restart() {  # bot_run_restart <service>
  local svc="$1" helper
  helper="$(bot_service_helper "${svc}")" || { err "no helper for service '${svc}'"; return 2; }
  NO_COLOR=1 bash "${SCRIPT_DIR}/${helper}" down \
    && NO_COLOR=1 bash "${SCRIPT_DIR}/${helper}" up
}

# `projects` listing: enumerate generated projects (read-only marker scan via
# bot-lib) and, if Docker is reachable, show each one's running/stopped state by
# the same `compose ps` primitive status.sh uses — without its full aggregation.
bot_run_projects_list() {
  local -a names=(); mapfile -t names < <(bot_list_projects)
  if (( ${#names[@]} == 0 )); then
    echo "No generated projects found under services/."
    echo "Create one with scripts/new-project.sh, then deploy with /project_up <name>."
    return 0
  fi
  local docker_ok=0
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then docker_ok=1; fi
  echo "Generated projects:"
  local p; for p in "${names[@]}"; do
    if (( ! docker_ok )); then
      printf '  • %s\n' "${p}"
      continue
    fi
    local -a cargs=(--project-directory "${PROJECT_ROOT}"
      -f "infrastructure/docker-compose.yml" -f "services/${p}/${p}.compose.yml")
    [[ -f "${PROJECT_ROOT}/.env" ]] && cargs=(--env-file "${PROJECT_ROOT}/.env" "${cargs[@]}")
    shopt -s nullglob
    local frag; for frag in "services/${p}/${p}".*.compose.yml; do cargs+=(-f "${frag}"); done
    shopt -u nullglob
    local running
    running="$(docker compose "${cargs[@]}" ps -q 2>/dev/null | grep -c . || true)"
    if [[ "${running:-0}" -gt 0 ]]; then
      printf '  • %s — up (%s container(s))\n' "${p}" "${running}"
    else
      printf '  • %s — down\n' "${p}"
    fi
  done
  echo
  echo "Start/stop with /project_up <name> or /project_down <name>."
}

# ===========================================================================
# Parse invocation -> ACTION + ARG (no eval, ever)
# ===========================================================================
ACTION=""; ARG=""

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --from-ssh)
    # SSH forced-command path: the requested command is in $SSH_ORIGINAL_COMMAND.
    # Tokenize it SAFELY (word-split only; no glob, no eval) and re-validate.
    _raw="${SSH_ORIGINAL_COMMAND:-}"
    # n8n's SSH node may prepend a working-directory hop ("cd <dir> && <cmd>").
    # Tolerate exactly that recognised prefix so a forced-command setup parses
    # cleanly; anything else is left intact and will fail action validation.
    if [[ "${_raw}" =~ ^cd[[:space:]]+[^[:space:]]+[[:space:]]+\&\&[[:space:]]+(.*)$ ]]; then
      _raw="${BASH_REMATCH[1]}"
    fi
    set -f
    # shellcheck disable=SC2206
    read -r -a _SSH_TOKENS <<< "${_raw}"
    set +f
    if (( ${#_SSH_TOKENS[@]} == 0 )); then
      refuse "" "" "empty SSH command (set TELEGRAM allowlist + send a valid action)"
    fi
    ACTION="${_SSH_TOKENS[0]:-}"
    ARG="${_SSH_TOKENS[1]:-}"
    if (( ${#_SSH_TOKENS[@]} > 2 )); then
      refuse "${ACTION}" "${ARG}" "too many arguments via SSH (expected: <action> [arg])"
    fi
    ;;
  "")
    err "no action given."
    usage >&2
    exit 2
    ;;
  *)
    ACTION="${1}"
    ARG="${2:-}"
    if (( $# > 2 )); then
      refuse "${ACTION}" "${ARG}" "too many arguments (expected: <action> [arg])"
    fi
    ;;
esac

# ===========================================================================
# VALIDATE — action allowlist, then per-action argument rules
# ===========================================================================
ACTION="${ACTION,,}"   # actions are lowercase
if ! bot_valid_action "${ACTION}"; then
  refuse "${ACTION}" "${ARG}" "unknown action '${ACTION}' (not in the whitelist)"
fi

CLASS="$(bot_action_class "${ACTION}")"
RULE="$(bot_action_arg_rule "${ACTION}")"

case "${RULE}" in
  none)
    [[ -z "${ARG}" ]] || refuse "${ACTION}" "${ARG}" "action '${ACTION}' takes no argument"
    ;;
  profile)
    [[ -n "${ARG}" ]] || ARG="${BOT_DEFAULT_PROFILE}"          # default profile
    bot_valid_profile "${ARG}" \
      || refuse "${ACTION}" "${ARG}" "invalid profile '${ARG}' (allowed: core dev auth automation)"
    ;;
  project)
    [[ -n "${ARG}" ]] || refuse "${ACTION}" "${ARG}" "action '${ACTION}' requires a project name"
    bot_valid_project_name "${ARG}" \
      || refuse "${ACTION}" "${ARG}" "malformed project name '${ARG}'"
    bot_known_project "${ARG}" \
      || refuse "${ACTION}" "${ARG}" "unknown project '${ARG}' (not a generated project under services/)"
    ;;
  service)
    [[ -n "${ARG}" ]] || refuse "${ACTION}" "${ARG}" "action '${ACTION}' requires a service name"
    bot_valid_service "${ARG}" \
      || refuse "${ACTION}" "${ARG}" "service '${ARG}' is not in the restart allowlist"
    ;;
  url)
    # Shape first (cheap fail-fast at the boundary). Then the SSRF guard CLI (which
    # uses classifyUrl — sync, no DNS) catches the operator-pasted mistakes that
    # matter on a Pi: non-http(s) scheme, credentials, literal internal IP, internal
    # hostname. The engine's probe re-checks every hop (DNS-rebinding). The URL is
    # passed as a SINGLE argv element to the SSRF helper — never via a shell string.
    [[ -n "${ARG}" ]] || refuse "${ACTION}" "${ARG}" "action '${ACTION}' requires a URL"
    bot_valid_url "${ARG}" \
      || refuse "${ACTION}" "${ARG}" "URL must be http(s) and contain no whitespace"
    SSRF_OUT="$(bot_run_ssrf_check "${ARG}" 2>&1)" || \
      refuse "${ACTION}" "${ARG}" "SSRF guard rejected the URL: ${SSRF_OUT}"
    unset SSRF_OUT
    ;;
esac

# ===========================================================================
# PLAN — the exact mapped command (string is for the human/audit log only;
# execution below uses argv arrays, never this string)
# ===========================================================================
PLAN=""
case "${ACTION}" in
  status)       PLAN="scripts/pi status" ;;
  health)       PLAN="scripts/pi health" ;;
  check)        PLAN="scripts/pi check" ;;
  projects)     PLAN="list generated projects (read-only)" ;;
  up)           PLAN="scripts/pi up --profile ${ARG} -y" ;;
  down)         PLAN="scripts/pi down --profile ${ARG} -y" ;;
  project_up)   PLAN="scripts/project.sh up ${ARG}" ;;
  project_down) PLAN="scripts/project.sh down ${ARG}" ;;
  restart)      PLAN="scripts/$(bot_service_helper "${ARG}") down && scripts/$(bot_service_helper "${ARG}") up" ;;
  monitor_metrics|monitor_alerts|backup_status|seo_audits|prospects_list)
                PLAN="scripts/panel-read.sh $(bot_panel_read_sub "${ACTION}") (read-only)" ;;
  audit_url|panel_audit_url)
                # The string form is informational only; execution below passes the URL
                # as a SINGLE argv element to seo.sh, never via this string.
                PLAN="scripts/seo.sh audit bot-audit --url ${ARG} --depth $(bot_audit_url_depth "${ACTION}")" ;;
esac

# Audit the (validated) request BEFORE running it.
log_event request "${ACTION}" "${ARG}" "${CLASS}" "result=ACCEPTED plan=[${PLAN}]"

# ---------------------------------------------------------------------------
# DRY-RUN: validation + logging only. Prints the plan; executes nothing. This is
# how tests verify mapping/validation/classification without Docker or Telegram.
# ---------------------------------------------------------------------------
if [[ "${BOT_EXEC_DRYRUN:-}" == "1" ]]; then
  printf 'PLAN: %s\n' "${PLAN}"
  printf 'ACTION=%s ARG=%s CLASS=%s\n' "${ACTION}" "${ARG:-"-"}" "${CLASS}"
  log_event dryrun "${ACTION}" "${ARG}" "${CLASS}" "result=DRYRUN"
  exit 0
fi

# ===========================================================================
# EXECUTE — run the mapped tool, capturing its exit code for the audit log
# ===========================================================================
rc=0
case "${ACTION}" in
  status)       bot_run_pi status || rc=$? ;;
  health)       bot_run_pi health || rc=$? ;;
  check)        bot_run_pi check  || rc=$? ;;
  projects)     bot_run_projects_list || rc=$? ;;
  up)           bot_run_pi up   --profile "${ARG}" -y || rc=$? ;;
  down)         bot_run_pi down --profile "${ARG}" -y || rc=$? ;;
  project_up)   bot_run_project up   "${ARG}" || rc=$? ;;
  project_down) bot_run_project down "${ARG}" || rc=$? ;;
  restart)      bot_run_restart "${ARG}" || rc=$? ;;
  monitor_metrics|monitor_alerts|backup_status|seo_audits|prospects_list)
                bot_run_panel_read "$(bot_panel_read_sub "${ACTION}")" || rc=$? ;;
  audit_url|panel_audit_url)
                # URL is the SECOND argv to bot_run_audit_url — never interpolated.
                bot_run_audit_url "$(bot_audit_url_depth "${ACTION}")" "${ARG}" || rc=$? ;;
esac

log_event result "${ACTION}" "${ARG}" "${CLASS}" "result=EXIT:${rc}"
exit "${rc}"
