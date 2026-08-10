# ===========================================================================
# pi-system — Telegram management bot: PURE LOGIC + mockable seams (sourced)
# ---------------------------------------------------------------------------
# The single SOURCE OF TRUTH for the bot's deterministic decision logic:
#
#   * the COMMAND PARSER (Telegram text  -> command + argument),
#   * the WHITELIST of commands and their mapping to bot-exec.sh ACTIONS,
#   * the ALLOWLIST AUTHORIZATION rule (is this Telegram user allowed?),
#   * READ-ONLY vs STATE-CHANGING classification, and
#   * argument validation (profile names / project names).
#
# It is intentionally tiny, side-effect-free and dependency-free so it can be
# both (a) sourced by scripts/bot-exec.sh (the audited host-side bridge) and
# (b) exercised offline by tests/bot/run.sh WITHOUT Docker or Telegram — exactly
# like scripts/lib/{ctl,startup,mem-budget,health-monitor}-lib.sh.
#
# NO AI / NO network / NO eval lives here. Every command is deterministic.
#
# IMPORTANT — keep in sync with the n8n workflow:
# automation/workflows/telegram-management-bot.json embeds a JavaScript Code node
# that MIRRORS these same tables (KNOWN commands, ACTION map, READ-ONLY set,
# argument rules, the allowlist rule). This bash library is the canonical
# reference and is the one covered by the test suite; if you change a table here,
# change it there too (a comment in that node points back to this file).
# ===========================================================================
# This file is meant to be SOURCED. No shebang; do not set -e here (the callers
# own their own error handling). Guard against double-sourcing.
[[ -n "${BOT_LIB_SOURCED:-}" ]] && return 0
BOT_LIB_SOURCED=1

# ---------------------------------------------------------------------------
# The WHITELIST.  command -> bot-exec ACTION.  `help` is answered in-workflow
# (and by bot_help_text) and has NO action — it never reaches the bridge.
# Anything not a key here is an UNKNOWN command and is refused.
# ---------------------------------------------------------------------------
declare -gA BOT_CMD_ACTION=(
  [status]=status
  [health]=health
  [check]=check
  [projects]=projects
  [up]=up
  [down]=down
  [project_up]=project_up
  [project_down]=project_down
  # Guarded "audit this URL" — operator pastes ONE http(s) URL; the bridge runs the
  # SAME SSRF-guarded SEO engine. /audit_url uses the standard depth (~1 AI call when
  # an AI key is set; free otherwise); /panel_audit_url uses the deep depth (full
  # multi-specialist panel, ≈ up to 7 AI calls). No competitors here — that needs
  # multiple URLs and stays a CLI feature (scripts/seo.sh audit --competitor ...).
  [audit_url]=audit_url
  [panel_audit_url]=panel_audit_url
  [help]=""           # in-workflow help; not an executable action
)

# The fixed set of ACTIONS bot-exec.sh will run. Derived intent, kept explicit
# (and independent of the command map) so the bridge can validate on its own.
# `restart` is invoked by the Control API after a config change (over the SAME
# SSH bridge); it is whitelisted to a known service list (BOT_VALID_SERVICE).
# The monitor_*/backup_status/seo_audits/prospects_list actions are the Control
# API's READ-ONLY panel-data feeds (Monitoring + Growth views) — each maps to
# scripts/panel-read.sh, which only READS the producers' status/log/store files.
declare -gA BOT_VALID_ACTION=(
  [status]=1 [health]=1 [check]=1 [projects]=1
  [up]=1 [down]=1 [project_up]=1 [project_down]=1
  [restart]=1
  [monitor_metrics]=1 [monitor_alerts]=1 [backup_status]=1 [seo_audits]=1 [prospects_list]=1
  [audit_url]=1 [panel_audit_url]=1
)

# READ-ONLY actions never change state. Everything else is STATE-CHANGING and
# must be logged by the bridge. The panel-data feeds are ALL read-only. The new
# audit_url actions ARE state-changing — they append to the SEO store (data/seo/
# audits/*.jsonl) and write a report file, so they must be logged.
declare -gA BOT_READONLY_ACTION=(
  [status]=1 [health]=1 [check]=1 [projects]=1
  [monitor_metrics]=1 [monitor_alerts]=1 [backup_status]=1 [seo_audits]=1 [prospects_list]=1
)

# Argument rules per action: "none" | "profile" (optional, defaults to core) |
# "project" (required, must be a known generated project) | "service" (required,
# must be in the restart allowlist) | "url" (required, http(s) + SSRF-checked).
# The panel-data feeds take NO argument.
declare -gA BOT_ACTION_ARG=(
  [status]=none [health]=none [check]=none [projects]=none
  [up]=profile [down]=profile
  [project_up]=project [project_down]=project
  [restart]=service
  [monitor_metrics]=none [monitor_alerts]=none [backup_status]=none [seo_audits]=none [prospects_list]=none
  [audit_url]=url [panel_audit_url]=url
)

# audit_url action -> the depth the bridge invokes the SEO engine at.
declare -gA BOT_AUDIT_URL_DEPTH=(
  [audit_url]=standard
  [panel_audit_url]=deep
)

# The panel-data READ actions -> their scripts/panel-read.sh subcommand (identical
# names). bot-exec maps each through this so there is ONE read-only door to the
# producers' files. Adding an action here without a panel-read subcommand is a bug.
declare -gA BOT_PANEL_READ=(
  [monitor_metrics]=monitor_metrics [monitor_alerts]=monitor_alerts
  [backup_status]=backup_status [seo_audits]=seo_audits [prospects_list]=prospects_list
)

# Boot profiles the bot is allowed to act on. Deliberately a SHORT allowlist of
# the runnable profiles from infrastructure/boot-profiles.conf — the illustrative
# "full-ish" reference profile is excluded on purpose (it is not meant to run).
declare -gA BOT_VALID_PROFILE=(
  [core]=1 [dev]=1 [auth]=1 [automation]=1
)

# Default profile when /up or /down is sent without one.
BOT_DEFAULT_PROFILE="core"

# Services the `restart` action may act on. Deliberately a SHORT allowlist of the
# stack helpers that own an up/down lifecycle. Each maps to its helper script
# under scripts/; a restart = that helper's `down` then `up` (which RECREATES the
# container so a changed .env value is actually picked up). control-api restarts
# itself. MUST stay in sync with services/control-api/lib/bridge-core.js
# (VALID_RESTART_SERVICES) and the registry's restart_services values.
declare -gA BOT_VALID_SERVICE=(
  [automation]=1 [analytics]=1 [auth]=1 [dashboard]=1 [cache]=1 [control-api]=1
)

# service -> the helper script (under scripts/) that owns its up/down lifecycle.
declare -gA BOT_SERVICE_HELPER=(
  [automation]=automation.sh
  [analytics]=analytics.sh
  [auth]=auth.sh
  [dashboard]=dashboard.sh
  [cache]=cache.sh
  [control-api]=control-api.sh
)

# Generated-project name shape (identical to scripts/project.sh / new-project.sh).
BOT_PROJECT_NAME_RE='^[a-z][a-z0-9-]{0,38}[a-z0-9]$'

# ===========================================================================
# Command parsing
# ===========================================================================
# bot_parse_command "<raw telegram text>"  ->  prints "<command>\t<arg>"
#
# Rules (deterministic, no eval):
#   * leading/trailing whitespace ignored; an optional leading '/' is stripped;
#   * the command is the FIRST whitespace token, lowercased, with any Telegram
#     "@botname" suffix removed (group chats append it: "/status@MyPiBot");
#   * the argument is the SECOND token verbatim (further tokens are ignored here;
#     the bridge rejects extra tokens). Empty input -> empty command.
# The command is returned RAW (not yet validated) — callers decide if it is known.
bot_parse_command() {
  local text="${1-}" cmd arg
  # Trim surrounding whitespace (incl. a stray CR from CRLF transports).
  text="${text%$'\r'}"
  text="${text#"${text%%[![:space:]]*}"}"
  text="${text%"${text##*[![:space:]]}"}"
  # Split into the first two whitespace tokens without globbing/eval.
  read -r cmd arg _ <<< "${text}"
  cmd="${cmd#/}"          # strip a single leading slash, if any
  cmd="${cmd%%@*}"        # strip a trailing @botname mention
  cmd="${cmd,,}"          # lowercase
  printf '%s\t%s' "${cmd}" "${arg}"
}

# Convenience extractors (handy in tests / callers).
bot_command_of() { bot_parse_command "${1-}" | cut -f1; }
bot_arg_of()     { bot_parse_command "${1-}" | cut -f2; }

# ===========================================================================
# Whitelist / classification predicates  (all: 0 = yes, 1 = no)
# ===========================================================================
# Guard: a subscript SAFE for associative-array lookup. Rejects the empty string
# AND the special tokens '@' / '*' (which would otherwise expand to the WHOLE
# array and falsely report a hit) AND anything with shell metacharacters. Every
# real key (commands, actions, profiles) is [a-z0-9_-]+, so this both silences
# "bad array subscript" and fails closed on hostile input.
_bot_safe_key() { [[ "${1-}" =~ ^[a-z0-9_-]+$ ]]; }

# A known (whitelisted) command — includes `help`.
bot_known_command() { _bot_safe_key "${1-}" && [[ -n "${BOT_CMD_ACTION[${1}]+x}" ]]; }

# The bot-exec action for a command ("" for help/unknown). Prints the action.
bot_action_for() {
  local cmd="${1-}"
  bot_known_command "${cmd}" || { printf ''; return 1; }
  printf '%s' "${BOT_CMD_ACTION[${cmd}]}"
}

# A valid bridge action (the fixed executable set; `help` is NOT one).
bot_valid_action() { _bot_safe_key "${1-}" && [[ -n "${BOT_VALID_ACTION[${1}]+x}" ]]; }

# Is this action read-only (must not change state)?
bot_is_readonly_action() { _bot_safe_key "${1-}" && [[ -n "${BOT_READONLY_ACTION[${1}]+x}" ]]; }

# Is this action state-changing (must be logged by the bridge)?
bot_is_state_action() { bot_valid_action "${1-}" && ! bot_is_readonly_action "${1-}"; }

# The argument rule for an action: prints none|profile|project.
bot_action_arg_rule() {
  bot_valid_action "${1-}" || { printf 'none'; return 1; }
  printf '%s' "${BOT_ACTION_ARG[${1-}]}"
}

# A human classification word (used in logs/replies): readonly|state-changing.
bot_action_class() { bot_is_readonly_action "${1-}" && printf 'readonly' || printf 'state-changing'; }

# ===========================================================================
# Argument validation
# ===========================================================================
# A valid, allowlisted boot profile.
bot_valid_profile() { _bot_safe_key "${1-}" && [[ -n "${BOT_VALID_PROFILE[${1}]+x}" ]]; }

# A valid, allowlisted restartable service.
bot_valid_service() { _bot_safe_key "${1-}" && [[ -n "${BOT_VALID_SERVICE[${1}]+x}" ]]; }

# The helper script that owns a (valid) service's up/down lifecycle. Prints the
# script name (under scripts/); returns non-zero for an unknown service.
bot_service_helper() {
  bot_valid_service "${1-}" || { printf ''; return 1; }
  printf '%s' "${BOT_SERVICE_HELPER[${1}]}"
}

# Is this a READ-ONLY panel-data action? (Control API Monitoring/Growth feeds.)
bot_is_panel_read() { _bot_safe_key "${1-}" && [[ -n "${BOT_PANEL_READ[${1}]+x}" ]]; }

# The scripts/panel-read.sh subcommand for a (valid) panel-read action. Prints the
# subcommand; returns non-zero for anything that is not a panel-read action.
bot_panel_read_sub() {
  bot_is_panel_read "${1-}" || { printf ''; return 1; }
  printf '%s' "${BOT_PANEL_READ[${1}]}"
}

# A syntactically valid generated-project name (shape only — not existence).
bot_valid_project_name() { [[ "${1-}" =~ ${BOT_PROJECT_NAME_RE} ]]; }

# Shape check for an operator-pasted URL: http or https, no whitespace. This is a
# friendly fail-fast at the boundary; the REAL SSRF refusal lives in the SSRF
# guard (services/seo/engine/ssrf-guard.js), invoked by the bridge BEFORE Docker
# via the ssrf-check.js CLI. The argv-array execFile pattern means even a URL
# with shell metacharacters is one token end-to-end — never interpolated.
bot_valid_url() {
  [[ "${1-}" =~ ^https?://[^[:space:]]+$ ]]
}

# The SEO engine depth this audit_url action runs at (standard | deep). Prints the
# depth; returns non-zero for anything that is not a URL-typed action.
bot_audit_url_depth() {
  _bot_safe_key "${1-}" || { printf ''; return 1; }
  [[ -n "${BOT_AUDIT_URL_DEPTH[${1}]+x}" ]] || { printf ''; return 1; }
  printf '%s' "${BOT_AUDIT_URL_DEPTH[${1}]}"
}

# ===========================================================================
# CREATE-PROJECT — the Control API GENERATION bridge allowlists + validators
# ---------------------------------------------------------------------------
# Used ONLY by scripts/bot-exec-generate.sh (the sibling generation bridge): the
# fixed, strictly-validated parameter set that maps to scripts/new-project.sh.
# These mirror new-project.sh's own flag validation AND the JS source of truth in
# services/control-api/lib/generate-core.js — the control-api test cross-checks
# the two so they cannot silently drift (exactly like the restart allowlist).
#
# NO --force is EVER reachable from this path: the bridge never offers that flag,
# so the API can never silently overwrite an existing project (it returns a
# conflict instead). Every value below is validated against an allowlist / strict
# pattern; anything else is REFUSED (never sanitized-and-run).
# ---------------------------------------------------------------------------
# Sector presets new-project.sh ships (declares base/db/locale/modules).
declare -gA BOT_VALID_PRESET=(
  [clinic]=1 [ecommerce]=1 [company-site]=1 [real-estate]=1
)
# Base shapes a project can be built from directly.
declare -gA BOT_VALID_BASE=(
  [dotnet-api]=1 [nextjs-app]=1 [fullstack]=1
)
# Database engines.
declare -gA BOT_VALID_DB=(
  [postgres]=1 [mysql]=1 [mongo]=1 [none]=1
)
# Default locales (ar => RTL).
declare -gA BOT_VALID_LOCALE=(
  [ar]=1 [en]=1
)
# Implemented, panel-exposed feature modules (the curated product set). The dev
# `hello-module` is deliberately NOT here — it is not offered through the panel.
declare -gA BOT_VALID_MODULE=(
  [i18n-bilingual]=1 [content-admin]=1 [bookings]=1 [auth-sso]=1
  [whatsapp-integration]=1 [local-payments]=1 [web-analytics]=1 [seo-toolkit]=1
)

# DNS-label shape for a project's public subdomain (identical to new-project.sh).
BOT_SUBDOMAIN_RE='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'

bot_valid_preset()    { _bot_safe_key "${1-}" && [[ -n "${BOT_VALID_PRESET[${1}]+x}" ]]; }
bot_valid_base()      { _bot_safe_key "${1-}" && [[ -n "${BOT_VALID_BASE[${1}]+x}" ]]; }
bot_valid_db()        { _bot_safe_key "${1-}" && [[ -n "${BOT_VALID_DB[${1}]+x}" ]]; }
bot_valid_locale()    { _bot_safe_key "${1-}" && [[ -n "${BOT_VALID_LOCALE[${1}]+x}" ]]; }
bot_valid_module()    { _bot_safe_key "${1-}" && [[ -n "${BOT_VALID_MODULE[${1}]+x}" ]]; }
bot_valid_subdomain() { [[ "${1-}" =~ ${BOT_SUBDOMAIN_RE} ]]; }

# A name to CREATE has the SAME shape as any generated-project name (so it never
# contains a path separator or shell metacharacter — only [a-z0-9-], letter-first).
bot_valid_create_name() { bot_valid_project_name "${1-}"; }

# Every module in a comma/space-separated list must be allowlisted. An empty list
# is OK (a base scaffold with no extra modules). Fails closed on the first unknown.
bot_valid_module_list() {
  local raw="${1-}" tok
  raw="${raw//,/ }"
  for tok in ${raw}; do
    bot_valid_module "${tok}" || return 1
  done
  return 0
}

# A project name that ALREADY EXISTS under services/ — the conflict guard. Uses the
# same discovery seam dir as bot_list_projects (honors BOT_SERVICES_DIR for tests).
# READ-ONLY. Returns 0 (true) if a directory for that name is already present.
bot_project_dir_exists() {
  local n="${1-}" dir="${BOT_SERVICES_DIR:-${BOT_PROJECT_ROOT:-.}/services}"
  [[ -e "${dir}/${n}" ]]
}

# ---------------------------------------------------------------------------
# Project discovery SEAM. Lists the names of GENERATED projects under services/
# — the ones carrying the `# pi-system-subdomain:` marker that distinguishes a
# scaffolded project from a platform service dir (the same convention used by
# status.sh / startup-lib's su_discover_projects). Self-contained on purpose so
# bot-lib has no heavy dependencies; honors BOT_SERVICES_DIR for tests. READ-ONLY.
# Override this function in a test to inject a fixed set.
# ---------------------------------------------------------------------------
bot_list_projects() {
  local dir="${BOT_SERVICES_DIR:-${BOT_PROJECT_ROOT:-.}/services}" d name frag
  [[ -d "${dir}" ]] || return 0
  for d in "${dir}"/*/; do
    [[ -d "${d}" ]] || continue
    name="$(basename "${d}")"
    frag="${d}/${name}.compose.yml"
    [[ -f "${frag}" ]] || continue
    grep -q '^# pi-system-subdomain:' "${frag}" 2>/dev/null && printf '%s\n' "${name}"
  done
}

# A KNOWN generated project = a valid name AND present in bot_list_projects.
bot_known_project() {
  local n="${1-}" p
  bot_valid_project_name "${n}" || return 1
  while IFS= read -r p; do [[ "${p}" == "${n}" ]] && return 0; done < <(bot_list_projects)
  return 1
}

# ===========================================================================
# Authorization — the locked allowlist of Telegram user ids
# ===========================================================================
# bot_authorized "<sender id>" "<allowed ids>"  ->  0 if allowed, 1 if denied.
#
# The allowlist is a comma/space/semicolon-separated list of NUMERIC Telegram
# user ids (TELEGRAM_ALLOWED_IDS). SECURITY RULES, fail-closed:
#   * an empty/blank sender id is ALWAYS denied;
#   * an EMPTY allowlist denies EVERYONE (a bot with no allowlist controls
#     nothing — never an open bot);
#   * only an EXACT id match authorizes.
bot_authorized() {
  local sender="${1-}" allowed="${2-}" id
  [[ -n "${sender}" ]] || return 1
  # No allowlist configured -> deny all (fail closed).
  [[ -n "${allowed//[[:space:],;]/}" ]] || return 1
  # Exact match against each whitespace/comma/semicolon-separated entry.
  local _ifs="${IFS}"; IFS=$' \t\n,;'
  # shellcheck disable=SC2086
  set -f; local -a ids=(${allowed}); set +f
  IFS="${_ifs}"
  for id in "${ids[@]}"; do
    [[ -n "${id}" && "${id}" == "${sender}" ]] && return 0
  done
  return 1
}

# ===========================================================================
# Help text (mirrored by the workflow's /help reply)
# ===========================================================================
bot_help_text() {
  cat <<'EOF'
pi-system bot — commands (operator only)

Read-only:
  /status            whole-system snapshot (up / off / broken + verdict)
  /health            host hardware health (temp / disk / memory)
  /check             read-only readiness gates (preflight + memory budget)
  /projects          list generated projects and their state

State-changing (logged):
  /up <profile>      bring a profile up   (core | dev | auth | automation; default core)
  /down <profile>    take a profile down  (default core)
  /project_up <name>     start a generated project
  /project_down <name>   stop a generated project
  /audit_url <url>       audit a single http(s) URL (SSRF-guarded; standard depth)
  /panel_audit_url <url> same, deep depth (multi-specialist panel — up to ~7 AI calls)

  /help              this message

Anything else is refused. Only allowlisted Telegram users may use this bot.
EOF
}
