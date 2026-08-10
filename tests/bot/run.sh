#!/usr/bin/env bash
# ===========================================================================
# pi-system — TELEGRAM MANAGEMENT BOT test harness
# ---------------------------------------------------------------------------
# Exercises the bot's deterministic logic WITHOUT Docker, n8n or Telegram —
# mirroring tests/{ctl,startup,mem-budget,health-monitor,preflight}/run.sh.
#
# Coverage (each maps to a real way the bot could go wrong):
#   * COMMAND PARSER       -> bot_parse_command (slash, @mention, casing, args)
#   * WHITELIST            -> bot_known_command / bot_action_for / bot_valid_action
#   * CLASSIFICATION       -> read-only vs state-changing + per-action arg rule
#   * ARGUMENT VALIDATION  -> profiles, project-name shape, KNOWN-project (fixtures)
#   * ALLOWLIST AUTH       -> bot_authorized: allowed vs denied vs empty (fail closed)
#   * HELP                 -> bot_help_text lists every command
#   * THE BRIDGE (real bot-exec.sh, dry-run): unknown action / bad arg REFUSED;
#     valid actions map to the right tool; default profile; read-only vs state
#     classification; --from-ssh parsing + INJECTION rejection; audit logging
#   * INTEGRITY            -> scripts parse; the workflow JSON is valid + complete
#   * SECRETS              -> check-secrets.sh warns on token-without-allowlist
#
# Usage:   ./tests/bot/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LIB="${PROJECT_ROOT}/scripts/lib/bot-lib.sh"
EXEC="${PROJECT_ROOT}/scripts/bot-exec.sh"
EXECG="${PROJECT_ROOT}/scripts/bot-exec-generate.sh"
FIXSVC="${SCRIPT_DIR}/fixtures/services"
WF="${PROJECT_ROOT}/automation/workflows/telegram-management-bot.json"

if [[ ! -f "${LIB}" ]]; then
  printf 'FATAL: library not found: %s\n' "${LIB}" >&2
  exit 2
fi
export BOT_PROJECT_ROOT="${PROJECT_ROOT}"
# shellcheck source=../../scripts/lib/bot-lib.sh
source "${LIB}"

# --- Colours (off when not a TTY) ------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; O=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; O=''
fi

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
# ok NAME CMD... : passes if CMD returns 0
ok()   { tests_run=$((tests_run+1)); if "${@:2}"; then _pass "$1"; else _fail "$1 (expected success)"; fi; }
# no NAME CMD... : passes if CMD returns non-zero
no()   { tests_run=$((tests_run+1)); if "${@:2}"; then _fail "$1 (expected failure)"; else _pass "$1"; fi; }
# has NAME HAYSTACK NEEDLE
has()  { tests_run=$((tests_run+1)); case "$2" in *"$3"*) _pass "$1" ;; *) _fail "$1 — [$2] missing [$3]" ;; esac; }
hasnt(){ tests_run=$((tests_run+1)); case "$2" in *"$3"*) _fail "$1 — [$2] unexpectedly has [$3]" ;; *) _pass "$1" ;; esac; }

# ===========================================================================
section "PARSE — command parser (pure)"
# ---------------------------------------------------------------------------
check "slash command"        "$(bot_parse_command '/status')"          "$(printf 'status\t')"
check "command + arg"        "$(bot_parse_command '/up core')"         "$(printf 'up\tcore')"
check "@botname stripped"    "$(bot_parse_command '/status@MyPiBot')"  "$(printf 'status\t')"
check "uppercased -> lower"  "$(bot_parse_command 'STATUS')"           "$(printf 'status\t')"
check "no leading slash"     "$(bot_parse_command 'health')"           "$(printf 'health\t')"
check "extra tokens dropped" "$(bot_command_of '/up core extra')"      "up"
check "arg of project_up"    "$(bot_arg_of '/project_up acme-portal')" "acme-portal"
check "leading/trailing ws"  "$(bot_command_of '   /check   ')"        "check"
check "empty -> empty cmd"   "$(bot_command_of '')"                    ""

# ===========================================================================
section "WHITELIST — known commands & action mapping (pure)"
# ---------------------------------------------------------------------------
for c in status health check projects up down project_up project_down help; do
  ok "known: /${c}" bot_known_command "${c}"
done
no "unknown: /reboot"       bot_known_command reboot
no "unknown: /rm"           bot_known_command rm
no "unknown: empty"         bot_known_command ''
check "action of /status"        "$(bot_action_for status)"       "status"
check "action of /project_up"    "$(bot_action_for project_up)"   "project_up"
check "action of /help (none)"   "$(bot_action_for help; true)"   ""
ok   "valid action: up"          bot_valid_action up
no   "help is NOT a bridge action" bot_valid_action help
no   "valid action rejects junk" bot_valid_action 'foo;bar'
no   "valid action rejects @"    bot_valid_action '@'
no   "valid action rejects *"    bot_valid_action '*'
no   "valid action rejects empty" bot_valid_action ''
no   "known cmd rejects @"       bot_known_command '@'

# ===========================================================================
section "CLASSIFY — read-only vs state-changing + arg rules (pure)"
# ---------------------------------------------------------------------------
for a in status health check projects; do ok "read-only: ${a}" bot_is_readonly_action "${a}"; done
for a in up down project_up project_down restart; do
  ok "state-changing: ${a}" bot_is_state_action "${a}"
  no "not read-only: ${a}"  bot_is_readonly_action "${a}"
done
check "arg rule restart"    "$(bot_action_arg_rule restart)"    "service"
check "class status"        "$(bot_action_class status)"        "readonly"
check "class up"            "$(bot_action_class up)"            "state-changing"
check "arg rule status"     "$(bot_action_arg_rule status)"     "none"
check "arg rule up"         "$(bot_action_arg_rule up)"         "profile"
check "arg rule project_up" "$(bot_action_arg_rule project_up)" "project"

# The Control API READ-ONLY panel-data feeds (part #4): read-only, take no arg,
# NEVER a state-changing path, and each resolves to a panel-read.sh subcommand.
for a in monitor_metrics monitor_alerts backup_status seo_audits prospects_list; do
  ok "valid action: ${a}"        bot_valid_action "${a}"
  ok "read-only: ${a}"           bot_is_readonly_action "${a}"
  no "NOT state-changing: ${a}"  bot_is_state_action "${a}"
  ok "is a panel-read: ${a}"     bot_is_panel_read "${a}"
  check "arg rule ${a}"          "$(bot_action_arg_rule "${a}")" "none"
  check "panel sub ${a}"         "$(bot_panel_read_sub "${a}")"  "${a}"
  no "NOT a Telegram command: ${a}" bot_known_command "${a}"
done
no "status is NOT a panel-read"  bot_is_panel_read status
no "restart is NOT a panel-read" bot_is_panel_read restart

# ===========================================================================
section "ARG VALIDATION — profiles / project names (pure + fixtures)"
# ---------------------------------------------------------------------------
for p in core dev auth automation; do ok "profile ok: ${p}" bot_valid_profile "${p}"; done
no "profile reject: full-ish"  bot_valid_profile full-ish
no "profile reject: bogus"     bot_valid_profile bogus
no "profile reject: injection" bot_valid_profile 'core;rm'
# Restart-service allowlist (the Control API config-change path).
for s in automation analytics auth dashboard cache control-api; do ok "service ok: ${s}" bot_valid_service "${s}"; done
no "service reject: postgres"  bot_valid_service postgres
no "service reject: injection" bot_valid_service 'auth;rm'
check "helper for automation"  "$(bot_service_helper automation)" "automation.sh"
check "helper for control-api" "$(bot_service_helper control-api)" "control-api.sh"
ok "name ok: acme-portal"      bot_valid_project_name acme-portal
no "name reject: UPPER"        bot_valid_project_name Acme
no "name reject: trailing -"   bot_valid_project_name 'acme-'
no "name reject: spaces"       bot_valid_project_name 'a b'
no "name reject: traversal"    bot_valid_project_name '../etc'

# KNOWN-project check against the fixture services dir (marker-based discovery).
export BOT_SERVICES_DIR="${FIXSVC}"
check "discovery lists acme-portal only" "$(bot_list_projects | paste -sd, -)" "acme-portal"
ok "known project: acme-portal" bot_known_project acme-portal
no "unknown project: ghost"     bot_known_project ghost
no "platform dir NOT a project" bot_known_project proxy
unset BOT_SERVICES_DIR

# ===========================================================================
section "CREATE — generation-bridge field validators (pure)"
# ---------------------------------------------------------------------------
# The allowlists scripts/bot-exec-generate.sh validates create-project against
# (mirrored in services/control-api/lib/generate-core.js — the control-api suite
# cross-checks them). Reject anything outside the allowlist; never sanitize.
for p in clinic ecommerce company-site real-estate; do ok "preset ok: ${p}" bot_valid_preset "${p}"; done
no "preset reject: wordpress" bot_valid_preset wordpress
no "preset reject: injection" bot_valid_preset 'clinic;rm'
for b in dotnet-api nextjs-app fullstack; do ok "base ok: ${b}" bot_valid_base "${b}"; done
no "base reject: rails"       bot_valid_base rails
for d in postgres mysql mongo none; do ok "db ok: ${d}" bot_valid_db "${d}"; done
no "db reject: oracle"        bot_valid_db oracle
for l in ar en; do ok "locale ok: ${l}" bot_valid_locale "${l}"; done
no "locale reject: fr"        bot_valid_locale fr
for m in i18n-bilingual content-admin bookings auth-sso whatsapp-integration local-payments web-analytics seo-toolkit; do
  ok "module ok: ${m}" bot_valid_module "${m}"
done
no "module reject: hello-module (dev-only)" bot_valid_module hello-module
no "module reject: rootkit"   bot_valid_module rootkit
no "module reject: injection" bot_valid_module 'bookings;rm'
ok "module list ok (csv)"     bot_valid_module_list 'i18n-bilingual,web-analytics'
ok "module list ok (spaces)"  bot_valid_module_list 'bookings auth-sso'
no "module list reject (one bad)" bot_valid_module_list 'bookings,evil'
ok "subdomain ok: noor"       bot_valid_subdomain noor
ok "subdomain ok: n00r-1"     bot_valid_subdomain n00r-1
no "subdomain reject: -bad-"  bot_valid_subdomain -bad-
no "subdomain reject: under_score" bot_valid_subdomain no_or
ok "create name ok: al-shifa" bot_valid_create_name al-shifa
no "create name reject: UPPER" bot_valid_create_name Acme
no "create name reject: traversal" bot_valid_create_name '../etc'
# Conflict guard against the fixture services dir.
export BOT_SERVICES_DIR="${FIXSVC}"
ok "conflict: acme-portal exists" bot_project_dir_exists acme-portal
no "no conflict: brand-new"        bot_project_dir_exists brand-new
unset BOT_SERVICES_DIR

# ===========================================================================
section "AUTH — allowlist authorization (fail closed)"
# ---------------------------------------------------------------------------
ok "allowed id (single)"          bot_authorized 111222333 '111222333'
ok "allowed id (in CSV)"          bot_authorized 444555666 '111222333,444555666'
ok "allowed id (space list)"      bot_authorized 444555666 '111222333 444555666'
no "denied id (not listed)"       bot_authorized 999000111 '111222333,444555666'
no "EMPTY allowlist denies all"   bot_authorized 111222333 ''
no "blank allowlist denies all"   bot_authorized 111222333 '   ,  ; '
no "empty sender denied"          bot_authorized '' '111222333'
no "substring is NOT a match"     bot_authorized 11122 '111222333'

# ===========================================================================
section "HELP — text lists every command (pure)"
# ---------------------------------------------------------------------------
HELP="$(bot_help_text)"
for c in /status /health /check /projects /up /down /project_up /project_down /help; do
  has "help mentions ${c}" "${HELP}" "${c}"
done
hasnt "help leaks no token" "${HELP}" "TOKEN"

# ===========================================================================
section "BRIDGE — scripts/bot-exec.sh validation & mapping (dry-run subprocess)"
# ---------------------------------------------------------------------------
TMPLOG="$(mktemp 2>/dev/null || echo "${SCRIPT_DIR}/.botlog.$$")"
: > "${TMPLOG}"
# run_exec ARGS... -> sets OUT (stdout+stderr) and RC (exit code). DRY-RUN only.
run_exec() {
  OUT="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" TELEGRAM_BOT_EXEC_LOG="${TMPLOG}" \
        bash "${EXEC}" "$@" 2>&1)"; RC=$?
}
# from_ssh CMD -> same, but via the SSH forced-command path.
from_ssh() {
  OUT="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" TELEGRAM_BOT_EXEC_LOG="${TMPLOG}" \
        SSH_ORIGINAL_COMMAND="$1" bash "${EXEC}" --from-ssh 2>&1)"; RC=$?
}

# -- valid actions map to the right tool, with correct classification --------
run_exec status;                 check "status rc"   "${RC}" "0"; has "status -> pi status" "${OUT}" "PLAN: scripts/pi status"; has "status is read-only" "${OUT}" "CLASS=readonly"
run_exec health;                 has "health -> pi health" "${OUT}" "PLAN: scripts/pi health"
run_exec check;                  has "check -> pi check"   "${OUT}" "PLAN: scripts/pi check"
run_exec projects;               has "projects -> list"    "${OUT}" "PLAN: list generated projects"
run_exec up;                     check "up rc" "${RC}" "0"; has "up defaults to core" "${OUT}" "PLAN: scripts/pi up --profile core -y"; has "up is state-changing" "${OUT}" "CLASS=state-changing"
run_exec up dev;                 has "up dev"   "${OUT}" "PLAN: scripts/pi up --profile dev -y"
run_exec down auth;              has "down auth" "${OUT}" "PLAN: scripts/pi down --profile auth -y"
run_exec project_up acme-portal; check "project_up rc" "${RC}" "0"; has "project_up maps" "${OUT}" "PLAN: scripts/project.sh up acme-portal"
run_exec project_down acme-portal; has "project_down maps" "${OUT}" "PLAN: scripts/project.sh down acme-portal"

# -- restart action (Control API config-change path): whitelisted services -----
run_exec restart analytics;      check "restart rc" "${RC}" "0"; has "restart maps to helper down+up" "${OUT}" "scripts/analytics.sh down && scripts/analytics.sh up"; has "restart is state-changing" "${OUT}" "CLASS=state-changing"
run_exec restart control-api;    check "restart control-api rc" "${RC}" "0"; has "restart control-api maps" "${OUT}" "scripts/control-api.sh down"
run_exec restart postgres;       check "restart non-whitelisted rc=2" "${RC}" "2"; has "restart refuses unknown service" "${OUT}" "not in the restart allowlist"
run_exec restart;                check "restart missing service rc=2" "${RC}" "2"; has "restart requires a service" "${OUT}" "requires a service name"

# -- READ-ONLY panel-data feeds (part #4): map to panel-read.sh, read-only -----
run_exec monitor_metrics;        check "monitor_metrics rc" "${RC}" "0"; has "monitor_metrics -> panel-read" "${OUT}" "PLAN: scripts/panel-read.sh monitor_metrics"; has "monitor_metrics read-only" "${OUT}" "CLASS=readonly"
run_exec monitor_alerts;         has "monitor_alerts -> panel-read"  "${OUT}" "PLAN: scripts/panel-read.sh monitor_alerts"
run_exec backup_status;          has "backup_status -> panel-read"   "${OUT}" "PLAN: scripts/panel-read.sh backup_status"
run_exec seo_audits;             has "seo_audits -> panel-read"      "${OUT}" "PLAN: scripts/panel-read.sh seo_audits"
run_exec prospects_list;         has "prospects_list -> panel-read"  "${OUT}" "PLAN: scripts/panel-read.sh prospects_list"
run_exec monitor_metrics extra;  check "read action refuses arg rc=2" "${RC}" "2"; has "read action takes no arg" "${OUT}" "takes no argument"
run_exec monitor_metrics; hasnt "read action never plans a state-changing tool" "${OUT}" "pi up"

# -- refusals: unknown action / bad arg / wrong arity ------------------------
run_exec reboot;                 check "unknown action rc=2" "${RC}" "2"; has "unknown action refused" "${OUT}" "unknown action"
run_exec up bogus;               check "bad profile rc=2"    "${RC}" "2"; has "bad profile refused"  "${OUT}" "invalid profile"
run_exec status extra;           check "no-arg+arg rc=2"     "${RC}" "2"; has "no-arg action refuses arg" "${OUT}" "takes no argument"
run_exec project_up;             check "missing name rc=2"   "${RC}" "2"; has "missing project refused" "${OUT}" "requires a project name"
run_exec project_up ghost;       check "unknown project rc=2" "${RC}" "2"; has "unknown project refused" "${OUT}" "unknown project"
run_exec project_up proxy;       check "platform-as-project rc=2" "${RC}" "2"; has "platform dir refused" "${OUT}" "unknown project"
run_exec project_up 'Bad Name';  check "malformed name rc=2" "${RC}" "2"
run_exec up core extra;          check "too many args rc=2"  "${RC}" "2"; has "too many args refused" "${OUT}" "too many arguments"
run_exec;                        check "no action rc=2"      "${RC}" "2"

# -- SSH forced-command path: parse + injection rejection --------------------
from_ssh "status";               check "ssh status rc=0" "${RC}" "0"; has "ssh status plans" "${OUT}" "PLAN: scripts/pi status"
from_ssh "up core";              has "ssh up core plans" "${OUT}" "PLAN: scripts/pi up --profile core -y"
from_ssh "cd /root && status";   check "ssh cd-prefix tolerated rc=0" "${RC}" "0"; has "ssh cd-prefix -> status" "${OUT}" "PLAN: scripts/pi status"
from_ssh "status; rm -rf /";     check "ssh injection rc=2" "${RC}" "2"; has "ssh injection refused" "${OUT}" "refused:"
from_ssh "status && reboot";     check "ssh chain rc=2" "${RC}" "2"
from_ssh "";                     check "ssh empty rc=2" "${RC}" "2"

# -- read-only commands must NOT plan a state-changing tool ------------------
run_exec status;  hasnt "status never plans 'up'"   "${OUT}" "pi up"
run_exec check;   hasnt "check never plans 'down'"  "${OUT}" "down --profile"

# -- audit logging: every invocation is recorded ----------------------------
run_exec up core
tests_run=$((tests_run+1))
if grep -q "action=up" "${TMPLOG}" && grep -q "result=DRYRUN" "${TMPLOG}"; then
  _pass "audit log records the invocation"
else
  _fail "audit log missing the up invocation"
fi
tests_run=$((tests_run+1))
if grep -q "result=REFUSED" "${TMPLOG}"; then _pass "audit log records refusals"; else _fail "refusal not logged"; fi
rm -f "${TMPLOG}"

# ===========================================================================
section "GENERATE BRIDGE — scripts/bot-exec-generate.sh (dry-run subprocess)"
# ---------------------------------------------------------------------------
# The sibling generation bridge: strictly-validated create-project -> new-project.sh
# ARGV (NO --force, never a shell). Conflict (existing name) exits 3 -> API 409.
TMPG="$(mktemp 2>/dev/null || echo "${SCRIPT_DIR}/.genlog.$$")"; : > "${TMPG}"
run_gen() {
  OUTG="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" CONTROL_API_GENERATE_LOG="${TMPG}" \
        bash "${EXECG}" "$@" 2>&1)"; RCG=$?
}
ssh_gen() {
  OUTG="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" CONTROL_API_GENERATE_LOG="${TMPG}" \
        SSH_ORIGINAL_COMMAND="$1" bash "${EXECG}" --from-ssh 2>&1)"; RCG=$?
}
run_gen create-project --name noor-store --preset ecommerce --db postgres --subdomain noor --locale ar --modules i18n-bilingual,web-analytics
check "valid create rc=0" "${RCG}" "0"; has "create maps to new-project.sh" "${OUTG}" "PLAN: scripts/new-project.sh --name noor-store --preset ecommerce"; has "create keeps modules csv" "${OUTG}" "--modules i18n-bilingual,web-analytics"
hasnt "create NEVER plans --force" "${OUTG}" "--force"
run_gen create-project --name acme --base fullstack --db none --locale en
check "valid base create rc=0" "${RCG}" "0"; has "base path maps" "${OUTG}" "--base fullstack"
run_gen create-project --name acme-portal --preset clinic --db postgres
check "existing name conflict rc=3" "${RCG}" "3"; has "conflict reason" "${OUTG}" "already exists"
run_gen create-project --name x1 --preset clinic --db postgres --modules hello-module
check "dev/unknown module rc=2" "${RCG}" "2"; has "module refusal" "${OUTG}" "unimplemented module"
run_gen create-project --name ../etc --preset clinic --db postgres
check "traversal name rc=2" "${RCG}" "2"
run_gen create-project --name 'a;rm' --preset clinic --db postgres
check "metachar name rc=2" "${RCG}" "2"
run_gen create-project --name ok --preset clinic --base fullstack --db postgres
check "both preset+base rc=2" "${RCG}" "2"; has "exactly one reason" "${OUTG}" "exactly one"
run_gen create-project --name ok --db postgres
check "neither preset nor base rc=2" "${RCG}" "2"
run_gen create-project --name ok --preset bogus --db postgres
check "unknown preset rc=2" "${RCG}" "2"
run_gen create-project --name ok --preset clinic --db oracle
check "unknown db rc=2" "${RCG}" "2"
run_gen create-project --name ok --preset clinic --db postgres --subdomain '-bad-'
check "bad subdomain rc=2" "${RCG}" "2"
run_gen create-project --name ok --preset clinic --db postgres --force
check "stray --force flag rc=2" "${RCG}" "2"
run_gen status
check "non-generate action rc=2" "${RCG}" "2"; has "only create-project allowed" "${OUTG}" "only 'create-project'"
ssh_gen "create-project --name web --preset clinic --db none"
check "ssh create rc=0" "${RCG}" "0"; has "ssh create plans" "${OUTG}" "PLAN: scripts/new-project.sh --name web --preset clinic"
ssh_gen "create-project --name web --preset clinic --db none; rm -rf /"
check "ssh injection rc=2" "${RCG}" "2"; has "ssh injection refused" "${OUTG}" "refused:"
ssh_gen "cd /root && create-project --name web --preset clinic --db none"
check "ssh cd-prefix tolerated rc=0" "${RCG}" "0"
# Audit: a creation request + a refusal are both recorded.
tests_run=$((tests_run+1)); if grep -q "action=create-project" "${TMPG}"; then _pass "generate audit records the request"; else _fail "generate audit missing"; fi
tests_run=$((tests_run+1)); if grep -q "result=CONFLICT" "${TMPG}"; then _pass "generate audit records conflicts"; else _fail "conflict not logged"; fi
rm -f "${TMPG}"

# ===========================================================================
section "AUDIT-URL — Telegram /audit_url <url>: SSRF-guarded, argv-passed, allowlist-gated"
# ---------------------------------------------------------------------------
# Two new bridge actions — audit_url (standard depth) + panel_audit_url (deep) —
# that audit ONE operator-pasted URL. Mirrors the existing bridge discipline
# exactly: the URL is passed as a SINGLE argv element to the executor (never
# interpolated into a shell string, never eval'd); shape + SSRF guard refuse
# obviously bad input BEFORE Docker spins up; the action is in the SAME
# allowlist-checked dispatch as the existing whitelisted actions; the audit
# trail records every invocation. Validated WITHOUT Docker / Telegram / network.
TMPLOG2="$(mktemp 2>/dev/null || echo "${SCRIPT_DIR}/.audit-url-log.$$")"; : > "${TMPLOG2}"

# A no-op SSRF stub for the dry-run path that doesn't require a literal-internal-IP
# rejection. The REAL ssrf-check.js is exercised end-to-end below (and directly).
SSRF_STUB_OK="$(mktemp 2>/dev/null || echo "${SCRIPT_DIR}/.ssrf-ok.$$")"
cat > "${SSRF_STUB_OK}" <<'OKSH'
#!/usr/bin/env bash
exit 0
OKSH
chmod +x "${SSRF_STUB_OK}"

run_url() {  # run_url <action> <url>
  OUT="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" \
         TELEGRAM_BOT_EXEC_LOG="${TMPLOG2}" \
         BOT_SSRF_CHECK_CMD="${SSRF_STUB_OK}" \
         bash "${EXEC}" "$1" "$2" 2>&1)"; RC=$?
}

# (1) Allowlist + bridge dispatch: both actions are recognized, validated, mapped.
run_url audit_url       "https://example.com/"
check "audit_url rc=0"        "${RC}" "0"
has   "audit_url plans depth=standard" "${OUT}" "scripts/seo.sh audit bot-audit --url https://example.com/ --depth standard"
has   "audit_url logged as state-changing" "${OUT}" "CLASS=state-changing"
run_url panel_audit_url "https://example.com/"
check "panel_audit_url rc=0"  "${RC}" "0"
has   "panel_audit_url plans depth=deep" "${OUT}" "--depth deep"

# (2) Shape refusals BEFORE Docker — non-http, embedded credentials, whitespace.
run_url audit_url "ftp://example.com/"
check "non-http scheme rc=2"  "${RC}" "2"; has "non-http refused" "${OUT}" "URL must be http(s)"
run_url audit_url ""
check "empty url rc=2"        "${RC}" "2"; has "empty url refused" "${OUT}" "requires a URL"
run_url audit_url "http://example.com path"
check "whitespace url rc=2"   "${RC}" "2"

# (3) SSRF stub REFUSES (simulates ssrf-check.js refusing an internal target). The
#     bridge must refuse BEFORE the PLAN/dispatch — never running the executor.
SSRF_STUB_BLOCK="$(mktemp 2>/dev/null || echo "${SCRIPT_DIR}/.ssrf-block.$$")"
cat > "${SSRF_STUB_BLOCK}" <<'BLOCKSH'
#!/usr/bin/env bash
printf 'SSRF guard: refusing internal target (%s)\n' "$1" >&2
exit 2
BLOCKSH
chmod +x "${SSRF_STUB_BLOCK}"
OUT="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" \
       TELEGRAM_BOT_EXEC_LOG="${TMPLOG2}" \
       BOT_SSRF_CHECK_CMD="${SSRF_STUB_BLOCK}" \
       bash "${EXEC}" audit_url "http://10.0.0.1/" 2>&1)"; RC=$?
check "ssrf-refused rc=2"     "${RC}" "2"; has "ssrf refused (bridge surface)" "${OUT}" "SSRF guard rejected"
hasnt "ssrf-refused never planned the audit" "${OUT}" "PLAN: scripts/seo.sh"

# (4) The REAL ssrf-check.js refuses an obvious internal target offline (no DNS).
SSRFCHK="${PROJECT_ROOT}/services/seo/engine/ssrf-check.js"
tests_run=$((tests_run+1))
if [[ -f "${SSRFCHK}" ]]; then _pass "ssrf-check.js exists"; else _fail "ssrf-check.js missing"; fi
if command -v node >/dev/null 2>&1; then
  OUT="$(node "${SSRFCHK}" "http://127.0.0.1/" 2>&1)"; RC=$?
  check "ssrf-check refuses loopback rc=2" "${RC}" "2"
  has   "ssrf-check non-leaky reason"      "${OUT}" "SSRF guard:"
  OUT="$(node "${SSRFCHK}" "http://10.0.0.1/x" 2>&1)"; RC=$?
  check "ssrf-check refuses RFC1918 rc=2"  "${RC}" "2"
  OUT="$(node "${SSRFCHK}" "ftp://example.com/" 2>&1)"; RC=$?
  check "ssrf-check refuses non-http rc=2" "${RC}" "2"
  OUT="$(node "${SSRFCHK}" "http://user:pass@example.com/" 2>&1)"; RC=$?
  check "ssrf-check refuses creds-in-url rc=2" "${RC}" "2"
  OUT="$(node "${SSRFCHK}" "http://localhost/" 2>&1)"; RC=$?
  check "ssrf-check refuses localhost rc=2" "${RC}" "2"
  OUT="$(node "${SSRFCHK}" "" 2>&1)"; RC=$?
  check "ssrf-check refuses empty rc=2"    "${RC}" "2"
  # A public URL is approved (literal-IP path skips DNS — public domain via classifyUrl).
  OUT="$(node "${SSRFCHK}" "https://example.com/" 2>&1)"; RC=$?
  check "ssrf-check approves public rc=0"  "${RC}" "0"
else
  _skip "ssrf-check.js direct tests (node not available)"
fi

# (5) ARGV-PASSED — a URL with shell metacharacters is ONE argv element end-to-end.
# The bridge is invoked as: bash bot-exec.sh audit_url <url>. Bash splits argv,
# and the URL is propagated as a positional arg through the executor seam (never
# interpolated into a shell command string). We pass a URL embedding the exact
# metacharacters that would be dangerous if interpolated (";", "|", "$(...)",
# "`...`") and assert (a) the PLAN echoes it verbatim, (b) rc=0 (shape OK + SSRF
# stub OK), (c) a sentinel file the metas TRY to create never appears, and (d)
# the audit log records the URL VERBATIM. URL has no whitespace so the shape
# regex accepts it; it has every shell meta that could break a naive string.
SENTINEL_DIR="$(mktemp -d 2>/dev/null || echo "${SCRIPT_DIR}/.sentinel.$$")"
mkdir -p "${SENTINEL_DIR}"
SENTINEL_NAME="PWNED_BY_METACHAR"
# Use ${IFS} (bash internal field separator) to embed a space WITHOUT having a
# literal whitespace char in the URL — if the shell ever EXPANDED this URL,
# touch would receive two args (its path) and create the sentinel. Argv-passed,
# ${IFS} stays literal, so the sentinel must NOT appear.
META_URL='https://example.com/?p=$(touch${IFS}'"${SENTINEL_DIR}/${SENTINEL_NAME}"');pipe=|cat;back=`true`'
OUT="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" \
       TELEGRAM_BOT_EXEC_LOG="${TMPLOG2}" \
       BOT_SSRF_CHECK_CMD="${SSRF_STUB_OK}" \
       bash "${EXEC}" audit_url "${META_URL}" 2>&1)"; RC=$?
check "metachar url rc=0 (shape OK)" "${RC}" "0"
has   "metachar url planned verbatim" "${OUT}" "${META_URL}"
tests_run=$((tests_run+1))
if [[ -e "${SENTINEL_DIR}/${SENTINEL_NAME}" ]]; then
  _fail "ARGV ESCAPE: \$(touch ...) executed (sentinel ${SENTINEL_DIR}/${SENTINEL_NAME} appeared)"
else _pass "argv pass-through: \$(touch ...) embedded in URL did NOT execute"; fi
# Also verify the audit log captured the URL VERBATIM (no shell-stripping).
tests_run=$((tests_run+1))
if grep -qF -- "${META_URL}" "${TMPLOG2}"; then
  _pass "audit log records the URL verbatim (no shell-stripping)"
else _fail "audit log did not record the metachar URL verbatim"; fi
rm -rf "${SENTINEL_DIR}" "${SSRF_STUB_OK}" "${SSRF_STUB_BLOCK}" 2>/dev/null || true

# (6) The bridge passes the URL via execFile-style argv (not a shell string). We
# assert this STRUCTURALLY: the executor seam uses "${URL}" as a positional arg
# inside an argv-array call to bash, never via string interpolation into a command.
fhas "bot-exec passes URL as argv to seo.sh"        "${EXEC}" '"${SCRIPT_DIR}/seo.sh" audit bot-audit --url "${url}"'
fhas "bot-exec calls SSRF check before PLAN"        "${EXEC}" 'bot_run_ssrf_check "${ARG}"'
fhas "bot-exec ssrf-check is one-argv exec"         "${EXEC}" 'node "${PROJECT_ROOT}/services/seo/engine/ssrf-check.js" "$1"'
fhasnt "bot-exec NEVER concatenates URL into a shell string" "${EXEC}" 'bash -c.*${ARG}'
fhasnt "bot-exec NEVER eval's the URL"              "${EXEC}" 'eval.*${ARG}'

# (7) ALLOWLIST AUTH (fail closed) — the new actions go through the SAME allowlist
# the n8n workflow enforces (TELEGRAM_ALLOWED_IDS). An unlisted id is DENIED.
ok "audit_url allowlist: listed id allowed"   bot_authorized 12345 '12345,67890'
no "audit_url allowlist: unlisted id denied"  bot_authorized 99999 '12345,67890'
no "audit_url allowlist: empty allowlist denies all" bot_authorized 12345 ''
no "audit_url allowlist: empty sender denied" bot_authorized '' '12345'

# (8) PURE bot-lib wiring — audit_url is a known command + maps to the right action.
ok "bot-lib: /audit_url is known"              bot_known_command audit_url
ok "bot-lib: /panel_audit_url is known"        bot_known_command panel_audit_url
check "action of /audit_url"        "$(bot_action_for audit_url)"       "audit_url"
check "action of /panel_audit_url"  "$(bot_action_for panel_audit_url)" "panel_audit_url"
ok   "audit_url is a valid bridge action"      bot_valid_action audit_url
ok   "panel_audit_url is a valid bridge action" bot_valid_action panel_audit_url
no   "audit_url is NOT read-only"              bot_is_readonly_action audit_url
check "arg rule of audit_url"       "$(bot_action_arg_rule audit_url)"  "url"
check "depth of /audit_url"         "$(bot_audit_url_depth audit_url)"       "standard"
check "depth of /panel_audit_url"   "$(bot_audit_url_depth panel_audit_url)" "deep"
ok   "bot-lib: valid http url"      bot_valid_url "https://example.com/path"
no   "bot-lib: rejects ftp url"     bot_valid_url "ftp://example.com/"
no   "bot-lib: rejects url with space" bot_valid_url "http://x y"
no   "bot-lib: rejects empty url"   bot_valid_url ""

# (9) NO TRANSPORT/SCRAPER token added by the new action — the bridge orchestrates
#     the existing seo.sh; it brings no new outbound surface of its own.
tests_run=$((tests_run+1))
if grep -nE "nodemailer|createTransport|sendgrid|mailgun|twilio|puppeteer|playwright|cheerio|serpapi|googleapis|nominatim|smtplib|XMLHttpRequest|telegraf|node-telegram" \
   "${PROJECT_ROOT}/scripts/bot-exec.sh" "${PROJECT_ROOT}/scripts/lib/bot-lib.sh" \
   "${PROJECT_ROOT}/services/seo/engine/ssrf-check.js" >/dev/null 2>&1; then
  _fail "bridge or ssrf-check contains a transport/scraper token"
else _pass "bridge + ssrf-check have NO transport/scraper token"; fi

# (10) Audit log: the new action is recorded as ACCEPTED + state-changing.
tests_run=$((tests_run+1))
if grep -q "action=audit_url" "${TMPLOG2}" && grep -q "class=state-changing" "${TMPLOG2}"; then
  _pass "audit_url is recorded in the audit log (state-changing)"
else _fail "audit_url not recorded as state-changing"; fi
rm -f "${TMPLOG2}"

# ===========================================================================
section "INTEGRITY — scripts parse; workflow JSON valid & complete"
# ---------------------------------------------------------------------------
for f in scripts/lib/bot-lib.sh scripts/bot-exec.sh scripts/bot-exec-generate.sh scripts/panel-read.sh scripts/check-secrets.sh; do
  tests_run=$((tests_run+1))
  if bash -n "${PROJECT_ROOT}/${f}" 2>/dev/null; then _pass "syntax ok: ${f}"; else _fail "syntax error: ${f}"; fi
done
# The generation + panel-read bridges map to tools that exist.
tests_run=$((tests_run+1))
[[ -f "${PROJECT_ROOT}/scripts/new-project.sh" ]] && _pass "generate bridge target exists: scripts/new-project.sh" || _fail "missing scripts/new-project.sh"
tests_run=$((tests_run+1))
[[ -f "${PROJECT_ROOT}/scripts/panel-read.sh" ]] && _pass "panel-read target exists: scripts/panel-read.sh" || _fail "missing scripts/panel-read.sh"
# bot-exec maps to tools that actually exist.
for s in pi status.sh health-monitor.sh project.sh; do
  tests_run=$((tests_run+1))
  [[ -f "${PROJECT_ROOT}/scripts/${s}" ]] && _pass "bridge target exists: scripts/${s}" || _fail "missing scripts/${s}"
done
# The n8n workflow is valid JSON with the expected nodes (validated via python or node).
tests_run=$((tests_run+1))
if [[ ! -f "${WF}" ]]; then
  _fail "workflow JSON missing: ${WF}"
elif command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python || command -v python3)"
  if "${PY}" - "${WF}" <<'PYEOF' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
names={n["name"] for n in d["nodes"]}
need={"Telegram Trigger","Authorize, parse & plan","Execute on host?","Run bot-exec.sh on host"}
types={n["type"] for n in d["nodes"]}
assert need<=names, names
assert "n8n-nodes-base.telegramTrigger" in types
assert d["active"] is False
PYEOF
  then _pass "workflow JSON valid & complete (trigger + auth + bridge nodes, inactive)"
  else _fail "workflow JSON invalid or missing expected nodes"; fi
else
  _skip "workflow JSON structural check (no python available)"
fi

# ===========================================================================
section "SECRETS — check-secrets.sh Telegram cross-check (guarded)"
# ---------------------------------------------------------------------------
CS="${PROJECT_ROOT}/scripts/check-secrets.sh"
if [[ -f "${PROJECT_ROOT}/.env" ]]; then
  _skip "check-secrets cross-check (a real .env exists — not overwriting it)"
else
  # Open bot: token set, allowlist EMPTY -> must WARN.
  printf 'REDIS_PASSWORD=averylongredispasswordvalue123\nTELEGRAM_BOT_TOKEN=123456789:AAExampleExampleExampleExampleExampleExa\nTELEGRAM_ALLOWED_IDS=\n' > "${PROJECT_ROOT}/.env"
  OUT="$(bash "${CS}" 2>&1 || true)"
  has "warns: token set, allowlist empty" "${OUT}" "TELEGRAM_BOT_TOKEN is set but TELEGRAM_ALLOWED_IDS is EMPTY"
  # Locked bot: token + allowlist -> NO open-bot warning.
  printf 'REDIS_PASSWORD=averylongredispasswordvalue123\nTELEGRAM_BOT_TOKEN=123456789:AAExampleExampleExampleExampleExampleExa\nTELEGRAM_ALLOWED_IDS=111222333\n' > "${PROJECT_ROOT}/.env"
  OUT="$(bash "${CS}" 2>&1 || true)"
  hasnt "no open-bot warning when allowlist set" "${OUT}" "TELEGRAM_BOT_TOKEN is set but TELEGRAM_ALLOWED_IDS is EMPTY"
  has   "ok line when locked"        "${OUT}" "token set with a non-empty allowlist"
  rm -f "${PROJECT_ROOT}/.env"
fi

# ===========================================================================
section "NOTIFY-TELEGRAM — outbound alert sender (gated, masked, best-effort)"
# ---------------------------------------------------------------------------
# scripts/notify-telegram.sh is the bundled sender for HEALTH_NOTIFY_CMD / SEO_/
# PROSPECTS_NOTIFY_CMD. Prove (offline, no token/network): it skips cleanly when
# unconfigured, derives the chat id (explicit override > allowlist fallback), and
# NEVER prints the bot token. Live delivery is verified on the Pi with a real token.
NTG="${PROJECT_ROOT}/scripts/notify-telegram.sh"
tests_run=$((tests_run+1)); if bash -n "${NTG}" 2>/dev/null; then _pass "notify-telegram.sh syntax ok"; else _fail "notify-telegram.sh syntax error"; fi
NTGTMP="$(mktemp -d 2>/dev/null || echo "${SCRIPT_DIR}/.ntg.$$")"; mkdir -p "${NTGTMP}/scripts"
cp "${NTG}" "${NTGTMP}/scripts/"
printf 'TELEGRAM_BOT_TOKEN=\nTELEGRAM_ALLOWED_IDS=\n' > "${NTGTMP}/.env"
OUT="$(cd "${NTGTMP}" && echo body | bash scripts/notify-telegram.sh FAIL 2>&1)"; RC=$?
ok  "unconfigured notifier exits 0 (best-effort no-op)" test "${RC}" -eq 0
has "unconfigured notifier reports it skipped" "${OUT}" "not configured"
printf 'TELEGRAM_BOT_TOKEN=999:AAsecrettokenZZ\nTELEGRAM_ALLOWED_IDS=111222333,444\n' > "${NTGTMP}/.env"
OUT="$(cd "${NTGTMP}" && echo alertbody | TELEGRAM_NOTIFY_DRYRUN=1 bash scripts/notify-telegram.sh WARN 2>&1)"; RC=$?
ok  "dry-run exits 0 without sending" test "${RC}" -eq 0
has "dry-run derives chat id from the allowlist" "${OUT}" "chat_id=111222333"
has "dry-run masks the bot token" "${OUT}" "bot<token>"
no  "dry-run never prints the real token" grep -q "AAsecrettoken" <<<"${OUT}"
printf 'TELEGRAM_BOT_TOKEN=999:AAx\nTELEGRAM_ALLOWED_IDS=111\nTELEGRAM_ALERT_CHAT_ID=987654\n' > "${NTGTMP}/.env"
OUT="$(cd "${NTGTMP}" && echo hi | TELEGRAM_NOTIFY_DRYRUN=1 bash scripts/notify-telegram.sh TEST 2>&1)"
has "explicit TELEGRAM_ALERT_CHAT_ID overrides the allowlist" "${OUT}" "chat_id=987654"
rm -rf "${NTGTMP}" 2>/dev/null || true

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
