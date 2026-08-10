#!/usr/bin/env bash
# ===========================================================================
# pi-system — PROJECT GENERATION bridge (the audited boundary for create-project)
# ---------------------------------------------------------------------------
# The Control API must NOT run arbitrary host commands and must NOT silently
# overwrite a project. This sibling of scripts/bot-exec.sh follows the IDENTICAL
# security pattern, scoped to ONE thing: scaffolding a new project. It accepts
# exactly ONE action — `create-project` — with a FIXED, strictly-validated flag
# set, validates EVERY field against the allowlists in scripts/lib/bot-lib.sh,
# LOGS every invocation, and maps the request to scripts/new-project.sh as an
# ARGV ARRAY (execFile-style) — never a shell string, never `eval`.
#
#   THE ONE ACTION (anything else is refused):
#     create-project --name <slug>
#                    ( --preset <preset> | --base <shape> )
#                    [--modules <csv>] --db <engine>
#                    [--subdomain <label>] [--locale <ar|en>]
#       -> scripts/new-project.sh --name … (--preset|--base) … --db … …   (NO --force)
#
#   VALIDATION (fail closed; reject — never sanitize-then-run):
#     name      ^[a-z][a-z0-9-]{0,38}[a-z0-9]$ ; must NOT already exist (conflict)
#     preset    clinic|ecommerce|company-site|real-estate   (XOR --base)
#     base      dotnet-api|nextjs-app|fullstack             (XOR --preset)
#     modules   comma/space list, EVERY entry an implemented, allowlisted module
#     db        postgres|mysql|mongo|none
#     subdomain strict DNS label (defaults to <name>)
#     locale    ar|en (default ar)
#
# WHY NO --force: this path may never clobber. If the name exists we exit with a
# dedicated CONFLICT code (3) so the API can return HTTP 409 — the existing folder
# is left untouched. (new-project.sh also refuses without --force: defence in depth.)
#
# USAGE
#   scripts/bot-exec-generate.sh create-project --name … [flags]   # direct / tests
#   scripts/bot-exec-generate.sh --from-ssh                        # $SSH_ORIGINAL_COMMAND
#   scripts/bot-exec-generate.sh -h | --help
#
# HOW the Control API calls it SAFELY (mirrors the bot-exec bridge — see
# docs/README.md "Control panel"): the API container is NEVER given the Docker
# socket. It reaches the host over SSH using a DEDICATED key pinned to a forced
# command, so that key can ONLY ever launch THIS script:
#     command="bash /PATH/TO/pi-system/scripts/bot-exec-generate.sh --from-ssh",\
#     no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding <key...>
# The requested "create-project <flags>" arrives in $SSH_ORIGINAL_COMMAND, which
# --from-ssh tokenizes (read -ra, no eval) and re-validates here. Whether invoked
# directly or via SSH, the validation below is the real boundary — defence in depth.
#
# ENV KNOBS
#   BOT_EXEC_DRYRUN=1          validate + LOG + print the PLANned command, but do
#                              NOT execute it (used by tests; never touches Docker).
#   CONTROL_API_GENERATE_LOG   audit log path (default: ./data/control-api/generate-bridge.log)
#   BOT_SERVICES_DIR           services/ dir for the conflict check (tests override it).
#   NO_COLOR is exported to new-project.sh so output is plain text.
#
# Exit codes: 0 success; 2 = refused (unknown action / bad field / usage);
# 3 = CONFLICT (a project with that name already exists — nothing was written);
# otherwise new-project.sh's exit code. Run from anywhere — paths resolve to root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Load the pure decision logic (allowlists / validators) ----------------
export BOT_PROJECT_ROOT="${PROJECT_ROOT}"
LIB="${SCRIPT_DIR}/lib/bot-lib.sh"
if [[ ! -f "${LIB}" ]]; then
  printf '[bot-exec-generate][error] missing required library: %s\n' "${LIB}" >&2
  exit 2
fi
# shellcheck source=scripts/lib/bot-lib.sh
source "${LIB}"

# --- Audit log -------------------------------------------------------------
LOG_FILE="${CONTROL_API_GENERATE_LOG:-${PROJECT_ROOT}/data/control-api/generate-bridge.log}"

# Timestamp seam (overridable in tests for determinism).
gen_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Append one tab-separated audit line. Best-effort: a log we cannot write must
# never crash the bridge, but we DO surface it on stderr. There are no secrets in
# a create-project request, but we still log only the validated field names/values.
gen_log() {
  local line="$1" dir
  dir="$(dirname "${LOG_FILE}")"
  mkdir -p "${dir}" 2>/dev/null || true
  if ! printf '%s\n' "${line}" >> "${LOG_FILE}" 2>/dev/null; then
    printf '[bot-exec-generate][warn] could not write audit log: %s\n' "${LOG_FILE}" >&2
  fi
}

log_event() {  # log_event <phase> <name> <result>
  gen_log "$(gen_now)	$1	action=create-project	name=${2:-"-"}	$3"
}

# --- Tiny stderr helpers ---------------------------------------------------
err()    { printf '[bot-exec-generate][error] %s\n' "$*" >&2; }
refuse() { # refuse <name> <reason>
  err "refused: $2"
  log_event refused "${1:-}" "result=REFUSED reason=$2"
  exit 2
}
conflict() { # conflict <name> <reason>
  err "conflict: $2"
  log_event conflict "${1:-}" "result=CONFLICT reason=$2"
  exit 3
}

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# ===========================================================================
# Execution SEAM — the ONLY place new-project.sh runs. Overridable so tests never
# touch Docker/disk. Invoked with an ARGV ARRAY ("$@"), never a shell string.
# ===========================================================================
gen_run_new_project() { NO_COLOR=1 bash "${SCRIPT_DIR}/new-project.sh" "$@"; }

# ===========================================================================
# Collect invocation tokens -> a TOKENS array (no eval, ever)
# ===========================================================================
declare -a TOKENS=()
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  --from-ssh)
    # SSH forced-command path: the requested command is in $SSH_ORIGINAL_COMMAND.
    # Tokenize it SAFELY (word-split only; no glob, no eval) and re-validate.
    _raw="${SSH_ORIGINAL_COMMAND:-}"
    # Tolerate exactly an n8n/ssh "cd <dir> && <cmd>" working-directory hop, like
    # bot-exec.sh; anything else is left intact and will fail validation below.
    if [[ "${_raw}" =~ ^cd[[:space:]]+[^[:space:]]+[[:space:]]+\&\&[[:space:]]+(.*)$ ]]; then
      _raw="${BASH_REMATCH[1]}"
    fi
    set -f
    # shellcheck disable=SC2206
    read -r -a TOKENS <<< "${_raw}"
    set +f
    if (( ${#TOKENS[@]} == 0 )); then
      refuse "" "empty SSH command (expected: create-project <flags>)"
    fi
    ;;
  "")
    err "no action given."
    usage >&2
    exit 2
    ;;
  *)
    TOKENS=("$@")
    ;;
esac

# ===========================================================================
# Parse — fixed action + fixed flag set (each flag takes one value; no others)
# ===========================================================================
ACTION="${TOKENS[0]:-}"
ACTION="${ACTION,,}"
if [[ "${ACTION}" != "create-project" ]]; then
  refuse "" "unknown action '${ACTION}' (only 'create-project' is allowed)"
fi

NAME="" PRESET="" BASE="" DB="" SUBDOMAIN="" LOCALE="" MODULES=""
i=1
while (( i < ${#TOKENS[@]} )); do
  key="${TOKENS[i]}"
  val="${TOKENS[i+1]:-}"
  # Every known flag REQUIRES a value that is not itself another flag.
  if [[ -z "${val}" || "${val}" == --* ]]; then
    refuse "${NAME}" "missing value for '${key}'"
  fi
  case "${key}" in
    --name)      NAME="${val}" ;;
    --preset)    PRESET="${val}" ;;
    --base)      BASE="${val}" ;;
    --db)        DB="${val}" ;;
    --subdomain) SUBDOMAIN="${val}" ;;
    --locale)    LOCALE="${val}" ;;
    --modules)   MODULES="${val}" ;;
    *)           refuse "${NAME}" "unknown flag '${key}'" ;;
  esac
  i=$((i + 2))
done

# ===========================================================================
# VALIDATE — every field against the bot-lib allowlists / strict patterns
# ===========================================================================
[[ -n "${NAME}" ]] || refuse "" "create-project requires --name"
bot_valid_create_name "${NAME}" \
  || refuse "${NAME}" "invalid project name '${NAME}' (lowercase, letter-first, [a-z0-9-], 2-40, no trailing '-')"

# Exactly one of --preset / --base (a preset declares a base; a base is explicit).
if [[ -n "${PRESET}" && -n "${BASE}" ]]; then
  refuse "${NAME}" "provide exactly one of --preset or --base (not both)"
fi
if [[ -z "${PRESET}" && -z "${BASE}" ]]; then
  refuse "${NAME}" "provide --preset or --base"
fi
if [[ -n "${PRESET}" ]]; then
  bot_valid_preset "${PRESET}" || refuse "${NAME}" "unknown preset '${PRESET}'"
fi
if [[ -n "${BASE}" ]]; then
  bot_valid_base "${BASE}" || refuse "${NAME}" "unknown base shape '${BASE}'"
fi

[[ -n "${DB}" ]] || refuse "${NAME}" "create-project requires --db"
bot_valid_db "${DB}" || refuse "${NAME}" "invalid database engine '${DB}'"

LOCALE="${LOCALE:-ar}"
bot_valid_locale "${LOCALE}" || refuse "${NAME}" "invalid locale '${LOCALE}'"

SUBDOMAIN="${SUBDOMAIN:-${NAME}}"
bot_valid_subdomain "${SUBDOMAIN}" || refuse "${NAME}" "invalid subdomain '${SUBDOMAIN}' (must be a DNS label)"

if [[ -n "${MODULES}" ]]; then
  bot_valid_module_list "${MODULES}" || refuse "${NAME}" "unknown or unimplemented module in '${MODULES}'"
fi

# Conflict guard — never overwrite. (new-project.sh also refuses without --force.)
if bot_project_dir_exists "${NAME}"; then
  conflict "${NAME}" "a project named '${NAME}' already exists under services/"
fi

# ===========================================================================
# PLAN — the exact mapped command, built as an ARGV array. The string form is for
# the human/audit log ONLY; execution below uses the array, never this string.
# NOTE: --force is NEVER added here. There is no code path that adds it.
# ===========================================================================
declare -a NP_ARGS=( --name "${NAME}" )
if [[ -n "${PRESET}" ]]; then
  NP_ARGS+=( --preset "${PRESET}" )
else
  NP_ARGS+=( --base "${BASE}" )
fi
NP_ARGS+=( --db "${DB}" --subdomain "${SUBDOMAIN}" --locale "${LOCALE}" )
[[ -n "${MODULES}" ]] && NP_ARGS+=( --modules "${MODULES}" )

PLAN="scripts/new-project.sh ${NP_ARGS[*]}"

# Audit the (validated) request BEFORE running it.
log_event request "${NAME}" "result=ACCEPTED plan=[${PLAN}]"

# ---------------------------------------------------------------------------
# DRY-RUN: validation + logging only. Prints the plan; executes nothing. This is
# how tests verify mapping/validation without Docker or disk writes.
# ---------------------------------------------------------------------------
if [[ "${BOT_EXEC_DRYRUN:-}" == "1" ]]; then
  printf 'PLAN: %s\n' "${PLAN}"
  printf 'NAME=%s SUBDOMAIN=%s DB=%s LOCALE=%s\n' "${NAME}" "${SUBDOMAIN}" "${DB}" "${LOCALE}"
  log_event dryrun "${NAME}" "result=DRYRUN"
  exit 0
fi

# ===========================================================================
# EXECUTE — run new-project.sh with the ARGV array; capture its exit code.
# ===========================================================================
rc=0
gen_run_new_project "${NP_ARGS[@]}" || rc=$?
log_event result "${NAME}" "result=EXIT:${rc}"
exit "${rc}"
