#!/usr/bin/env bash
# ===========================================================================
# pi-system — CONTROL API test harness (offline: no Docker / network / Keycloak)
# ---------------------------------------------------------------------------
# Two layers, mirroring the other suites:
#   1. PURE LOGIC (node)  -> tests/control-api/lib.test.mjs imports the lib
#      modules directly and proves: the authz matrix (no token 401 / non-operator
#      403 / operator allowed), the config-registry ALLOWLIST (rejects any key not
#      in the manifest), that secret VALUES are NEVER returned (set/empty/masked),
#      the SAFE .env writer (structure preserved + backup + no value leaked, via a
#      mocked fs seam), the RESTART whitelist, and that bridge args are an ARRAY
#      (never a shell string).
#   2. SOURCE + BRIDGE (bash) -> static checks that NO endpoint/lib builds an
#      arbitrary shell command, the registry JSON is valid, the JS restart list
#      matches bot-lib's, the scripts parse, and bot-exec's `restart` action is
#      whitelisted (dry-run).
#
# Usage:   ./tests/control-api/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # NOT -e: run every check, then tally.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
API_DIR="${PROJECT_ROOT}/services/control-api"
LIB_DIR="${API_DIR}/lib"
APP_DIR="${API_DIR}/app"
REGISTRY="${API_DIR}/config-registry.json"
BOT_LIB="${PROJECT_ROOT}/scripts/lib/bot-lib.sh"
EXEC="${PROJECT_ROOT}/scripts/bot-exec.sh"
EXECG="${PROJECT_ROOT}/scripts/bot-exec-generate.sh"
PANEL="${PROJECT_ROOT}/scripts/panel-read.sh"
GENCORE="${LIB_DIR}/generate-core.js"
FIXSVC="${PROJECT_ROOT}/tests/bot/fixtures/services"   # acme-portal exists here (conflict)
PANELFIX="${SCRIPT_DIR}/fixtures/paneldata"            # live-data fixtures for panel-read

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
ok()   { tests_run=$((tests_run+1)); if "${@:2}"; then _pass "$1"; else _fail "$1 (expected success)"; fi; }
no()   { tests_run=$((tests_run+1)); if "${@:2}"; then _fail "$1 (expected failure)"; else _pass "$1"; fi; }
has()  { tests_run=$((tests_run+1)); case "$2" in *"$3"*) _pass "$1" ;; *) _fail "$1 — [$2] missing [$3]" ;; esac; }

# ===========================================================================
section "PURE LOGIC — tests/control-api/lib.test.mjs (node)"
# ---------------------------------------------------------------------------
NODE="$(command -v node || true)"
if [[ -z "${NODE}" ]]; then
  _skip "node not available — pure-logic suite (install Node to run it)"
else
  tests_run=$((tests_run+1))
  if "${NODE}" "${SCRIPT_DIR}/lib.test.mjs"; then
    _pass "lib.test.mjs (authz / allowlist / secrets / writer / restart / no-shell)"
  else
    _fail "lib.test.mjs reported failures (see output above)"
  fi
fi

# ===========================================================================
section "NO ARBITRARY SHELL — source never spawns a shell from input"
# ---------------------------------------------------------------------------
# The ONLY child-process primitive allowed is execFile (argv array, no shell). Any
# of these would mean a value could reach a shell — they must NOT appear.
# Strip comment-only lines first (the bridge's docs legitimately mention `sh -c` /
# shell to explain what it AVOIDS) so only ACTUAL CODE is scanned.
scan() { grep -RInE "$1" "${LIB_DIR}" "${APP_DIR}" 2>/dev/null | grep -vE ':[0-9]+:[[:space:]]*(//|\*|/\*)'; }
for pat in 'execSync' 'spawnSync' '\bexec\(' 'shell[[:space:]]*:[[:space:]]*true' '/bin/sh' '\bsh[[:space:]]+-c\b'; do
  tests_run=$((tests_run+1))
  hit="$(scan "${pat}")"
  if [[ -z "${hit}" ]]; then _pass "no '${pat}' in lib/ or app/ code"; else _fail "found '${pat}': ${hit}"; fi
done
# execFile IS used (the safe primitive) — confirm it is present in the bridge.
tests_run=$((tests_run+1))
if grep -q "execFile" "${LIB_DIR}/bridge.js"; then _pass "bridge uses execFile (argv, no shell)"; else _fail "bridge.js should use execFile"; fi

# ===========================================================================
section "REGISTRY JSON — valid + secrets flagged + no real values"
# ---------------------------------------------------------------------------
tests_run=$((tests_run+1))
if command -v python >/dev/null 2>&1 || command -v python3 >/dev/null 2>&1; then
  PY="$(command -v python || command -v python3)"
  if "${PY}" - "${REGISTRY}" <<'PYEOF' 2>/dev/null
import json,sys
d=json.load(open(sys.argv[1],encoding="utf-8"))
assert isinstance(d.get("integrations"),list) and d["integrations"]
ids={i["id"] for i in d["integrations"]}
assert {"telegram","ai","whatsapp","payments"} <= ids, ids
for integ in d["integrations"]:
    for k in integ["keys"]:
        assert "key" in k and "label" in k and "secret" in k
        # restart targets must be a list
        assert isinstance(k.get("restart_services",[]),list)
PYEOF
  then _pass "config-registry.json valid & complete (telegram/ai/whatsapp/payments)"
  else _fail "config-registry.json invalid or missing expected integrations"; fi
elif [[ -n "${NODE:-}" ]]; then
  if "${NODE}" -e "const d=require('${REGISTRY}');if(!Array.isArray(d.integrations)||!d.integrations.length)process.exit(1)"; then
    _pass "config-registry.json valid (node)"
  else _fail "config-registry.json invalid (node)"; fi
else
  _skip "registry JSON structural check (no python/node)"
fi

# ===========================================================================
section "CROSS-CHECK — JS restart allowlist == bot-lib BOT_VALID_SERVICE"
# ---------------------------------------------------------------------------
# Both must list the SAME services or the API could ask bot-exec to restart a
# service it refuses (or vice-versa). Extract each list and compare as sorted sets.
bash_services="$(grep -oE '\[[a-z0-9-]+\]=1' "${BOT_LIB}" | sed -n 's/.*\[\([a-z0-9-]*\)\]=1/\1/p' \
  | grep -E '^(automation|analytics|auth|dashboard|cache|control-api)$' | sort -u | paste -sd, -)"
js_services="$(grep -oE "'[a-z0-9-]+'" "${LIB_DIR}/bridge-core.js" | tr -d "'" \
  | grep -E '^(automation|analytics|auth|dashboard|cache|control-api)$' | sort -u | paste -sd, -)"
tests_run=$((tests_run+1))
if [[ -n "${bash_services}" && "${bash_services}" == "${js_services}" ]]; then
  _pass "restart allowlists match: ${bash_services}"
else
  _fail "restart allowlists DIFFER — bash=[${bash_services}] js=[${js_services}]"
fi

# ===========================================================================
section "BRIDGE — bot-exec 'restart' action is whitelisted (dry-run)"
# ---------------------------------------------------------------------------
TMPLOG="$(mktemp 2>/dev/null || echo "${SCRIPT_DIR}/.calog.$$")"
run_exec() { OUT="$(BOT_EXEC_DRYRUN=1 TELEGRAM_BOT_EXEC_LOG="${TMPLOG}" bash "${EXEC}" "$@" 2>&1)"; RC=$?; }
run_exec restart analytics;    ok "restart analytics accepted" test "${RC}" -eq 0; has "restart maps to helper down+up" "${OUT}" "analytics.sh down"
run_exec restart control-api;  ok "restart control-api accepted" test "${RC}" -eq 0
run_exec restart postgres;     ok "restart postgres refused (not whitelisted)" test "${RC}" -eq 2; has "refusal reason" "${OUT}" "not in the restart allowlist"
run_exec restart;              ok "restart with no service refused" test "${RC}" -eq 2
run_exec restart 'a;rm -rf /'; ok "restart with injection refused" test "${RC}" -eq 2
rm -f "${TMPLOG}"

# ===========================================================================
section "BRIDGE — bot-exec-generate.sh create-project (dry-run, no Docker)"
# ---------------------------------------------------------------------------
# The SIBLING generation bridge: strictly-validated create-project -> new-project.sh
# ARGV (NO --force, never a shell). Conflict (existing name) exits 3 -> API 409.
TMPGLOG="$(mktemp 2>/dev/null || echo "${SCRIPT_DIR}/.gcalog.$$")"
run_gen() { OUTG="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" CONTROL_API_GENERATE_LOG="${TMPGLOG}" bash "${EXECG}" "$@" 2>&1)"; RCG=$?; }
run_gen create-project --name noor-store --preset ecommerce --db postgres --subdomain noor --locale ar --modules i18n-bilingual,web-analytics
ok "valid create accepted" test "${RCG}" -eq 0
has "create maps to new-project.sh" "${OUTG}" "PLAN: scripts/new-project.sh --name noor-store --preset ecommerce"
has "create passes the modules CSV" "${OUTG}" "--modules i18n-bilingual,web-analytics"
no "create NEVER plans --force" grep -q -- '--force' <<<"${OUTG}"
run_gen create-project --name acme --base fullstack --db none --locale en
ok "valid base-shape create accepted" test "${RCG}" -eq 0; has "base path maps" "${OUTG}" "--base fullstack"
run_gen create-project --name acme-portal --preset clinic --db postgres
ok "existing name -> CONFLICT rc=3" test "${RCG}" -eq 3; has "conflict reason" "${OUTG}" "already exists"
run_gen create-project --name x1 --preset clinic --db postgres --modules hello-module
ok "unknown/dev module refused rc=2" test "${RCG}" -eq 2; has "module refusal reason" "${OUTG}" "unimplemented module"
run_gen create-project --name ../etc --preset clinic --db postgres
ok "path-traversal name refused rc=2" test "${RCG}" -eq 2
run_gen create-project --name 'a;rm' --preset clinic --db postgres
ok "shell-metachar name refused rc=2" test "${RCG}" -eq 2
run_gen create-project --name ok --preset clinic --base fullstack --db postgres
ok "BOTH preset+base refused rc=2" test "${RCG}" -eq 2
run_gen create-project --name ok --preset bogus --db postgres
ok "unknown preset refused rc=2" test "${RCG}" -eq 2
run_gen create-project --name ok --preset clinic --db oracle
ok "unknown db refused rc=2" test "${RCG}" -eq 2
run_gen create-project --name ok --preset clinic --db postgres --force
ok "stray --force flag refused rc=2" test "${RCG}" -eq 2
run_gen status
ok "non-generate action refused rc=2" test "${RCG}" -eq 2; has "only create-project allowed" "${OUTG}" "only 'create-project'"
# SSH forced-command path: parse + injection rejection.
OUTG="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" CONTROL_API_GENERATE_LOG="${TMPGLOG}" SSH_ORIGINAL_COMMAND='create-project --name web --preset clinic --db none' bash "${EXECG}" --from-ssh 2>&1)"; RCG=$?
ok "ssh create accepted rc=0" test "${RCG}" -eq 0
OUTG="$(BOT_EXEC_DRYRUN=1 BOT_SERVICES_DIR="${FIXSVC}" CONTROL_API_GENERATE_LOG="${TMPGLOG}" SSH_ORIGINAL_COMMAND='create-project --name web --preset clinic --db none; rm -rf /' bash "${EXECG}" --from-ssh 2>&1)"; RCG=$?
ok "ssh injection refused rc=2" test "${RCG}" -eq 2
rm -f "${TMPGLOG}"

# ===========================================================================
section "CROSS-CHECK — generate-core.js allowlists == bot-lib.sh (no drift)"
# ---------------------------------------------------------------------------
# Each allowlist must match between the JS (API layer) and bash (bridge layer) or
# the API could accept a value the bridge refuses (or vice-versa). We read the
# REAL values: node prints the JS array; a sourced bash prints the assoc keys.
cross_set() { # cross_set <label> <js-array-name> <bash-assoc-name>
  local label="$1" jsname="$2" bashname="$3" js bash_
  # Import via a RELATIVE specifier from the API dir (portable across OSes; an
  # absolute Windows path is not a valid ESM specifier).
  js="$(cd "${API_DIR}" && "${NODE}" --input-type=module -e "import * as m from './lib/generate-core.js'; console.log([...m.${jsname}].sort().join(','))" 2>/dev/null)"
  bash_="$(bash -c "source '${BOT_LIB}'; printf '%s\n' \"\${!${bashname}[@]}\" | sort | paste -sd, -" 2>/dev/null)"
  tests_run=$((tests_run+1))
  if [[ -n "${js}" && "${js}" == "${bash_}" ]]; then _pass "${label} match: ${js}"
  else _fail "${label} DIFFER — js=[${js}] bash=[${bash_}]"; fi
}
if [[ -n "${NODE}" ]]; then
  cross_set "presets" "VALID_PRESETS" "BOT_VALID_PRESET"
  cross_set "bases"   "VALID_BASES"   "BOT_VALID_BASE"
  cross_set "dbs"     "VALID_DBS"     "BOT_VALID_DB"
  cross_set "locales" "VALID_LOCALES" "BOT_VALID_LOCALE"
  cross_set "modules" "VALID_MODULES" "BOT_VALID_MODULE"
else
  _skip "generate allowlist cross-check (no node)"
fi

# ===========================================================================
section "GENERATE — operator-only, throttled, and NO --force anywhere"
# ---------------------------------------------------------------------------
# Helper: does a real (non-comment) code line in <files> contain <pattern>?
code_has() { grep -hvE '^[[:space:]]*(#|//|\*|/\*)' "${@:2}" 2>/dev/null | grep -qE -- "$1"; }
PROUTE="${APP_DIR}/api/projects/route.js"
tests_run=$((tests_run+1)); grep -q 'requireOperator: true' "${PROUTE}" && _pass "POST /api/projects requires the operator role" || _fail "POST /api/projects MUST require operator"
tests_run=$((tests_run+1)); grep -q 'consume(' "${PROUTE}" && _pass "POST /api/projects is rate-limited" || _fail "POST /api/projects MUST be throttled"
tests_run=$((tests_run+1)); grep -q 'executeGenerate' "${PROUTE}" && _pass "POST /api/projects routes through executeGenerate" || _fail "POST route should call executeGenerate"
# The API generation path must NEVER pass --force as an actual flag string.
tests_run=$((tests_run+1))
if code_has "['\"]--force['\"]" "${LIB_DIR}/generate-core.js" "${LIB_DIR}/generate.js" "${PROUTE}"; then
  _fail "the API generation path emits a --force flag (it must never overwrite)"
else _pass "no --force flag anywhere in the API generation path"; fi
# The bridge maps to new-project.sh via an ARGV array and never evals.
tests_run=$((tests_run+1)); grep -qF 'gen_run_new_project "${NP_ARGS[@]}"' "${EXECG}" && _pass "bot-exec-generate runs new-project.sh as an ARGV array" || _fail "bot-exec-generate should use an ARGV array"
tests_run=$((tests_run+1)); if code_has '\beval\b' "${EXECG}"; then _fail "bot-exec-generate must not use eval"; else _pass "bot-exec-generate never uses eval (code)"; fi
tests_run=$((tests_run+1)); if code_has -- '--force' "${EXECG}" "${BOT_LIB}"; then _fail "the bridge code references --force"; else _pass "the bridge never references --force (code)"; fi

# ===========================================================================
section "PANEL READ (part #4) — read-only data feeds emit valid JSON"
# ---------------------------------------------------------------------------
# scripts/panel-read.sh reads the producers' status/log/store files and prints
# JSON. Prove: each subcommand emits VALID JSON against the fixtures, an unknown
# subcommand is refused, and a missing data dir degrades to null/[] (never errors).
panel() { OUTP="$(PANEL_DATA_DIR="${PANELFIX}" bash "${PANEL}" "$1" 2>&1)"; RCP=$?; }
valid_json() { printf '%s' "$1" | "${NODE}" -e 'let d="";process.stdin.on("data",c=>d+=c);process.stdin.on("end",()=>{try{JSON.parse(d);process.exit(0)}catch{process.exit(1)}})'; }
if [[ -n "${NODE}" ]]; then
  for s in monitor_metrics monitor_alerts backup_status seo_audits prospects_list; do
    panel "${s}"
    ok "panel-read ${s} exits 0" test "${RCP}" -eq 0
    tests_run=$((tests_run+1)); if valid_json "${OUTP}"; then _pass "panel-read ${s} emits valid JSON"; else _fail "panel-read ${s} emitted invalid JSON"; fi
  done
  has "monitor_metrics carries the verdict" "$(PANEL_DATA_DIR="${PANELFIX}" bash "${PANEL}" monitor_metrics)" 'verdict'
  has "backup_status carries last-backup" "$(PANEL_DATA_DIR="${PANELFIX}" bash "${PANEL}" backup_status)" '20260523-020000'
  has "seo_audits carries an audit name" "$(PANEL_DATA_DIR="${PANELFIX}" bash "${PANEL}" seo_audits)" 'noor-store'
  has "prospects_list carries a prospect" "$(PANEL_DATA_DIR="${PANELFIX}" bash "${PANEL}" prospects_list)" 'alpha-co'
  # Missing data dir -> null/[] (a clean empty state, not an error).
  EMPTYD="$(mktemp -d 2>/dev/null || echo "${SCRIPT_DIR}/.empty.$$")"; mkdir -p "${EMPTYD}"
  OUT_EMPTY="$(PANEL_DATA_DIR="${EMPTYD}" bash "${PANEL}" monitor_metrics 2>&1)"; RCP=$?
  ok "panel-read on empty dir still exits 0" test "${RCP}" -eq 0
  has "empty dir -> lastHealth null" "${OUT_EMPTY}" '"lastHealth":null'
  rm -rf "${EMPTYD}" 2>/dev/null || true
else
  _skip "panel-read JSON checks (no node)"
fi
# Unknown subcommand is refused.
PANEL_DATA_DIR="${PANELFIX}" bash "${PANEL}" bogus >/dev/null 2>&1; RCP=$?
ok "panel-read refuses an unknown subcommand" test "${RCP}" -eq 2

# ===========================================================================
section "PANEL READ — proven READ-ONLY (fixtures untouched; no mutating verbs)"
# ---------------------------------------------------------------------------
# FUNCTIONAL proof: running every subcommand changes NO file under the data dir
# (same file list + same per-file checksums before and after).
snap() { find "$1" -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do printf '%s:' "${f#${1}/}"; cksum < "${f}"; done; }
BEFORE="$(snap "${PANELFIX}")"
for s in monitor_metrics monitor_alerts backup_status seo_audits prospects_list; do
  PANEL_DATA_DIR="${PANELFIX}" bash "${PANEL}" "${s}" >/dev/null 2>&1 || true
done
AFTER="$(snap "${PANELFIX}")"
tests_run=$((tests_run+1)); if [[ "${BEFORE}" == "${AFTER}" ]]; then _pass "reads left every fixture file byte-identical"; else _fail "panel-read MODIFIED a data file (must be read-only)"; fi
# STATIC proof: no mutating command appears in real (non-comment) code.
code_only() { grep -hvE '^[[:space:]]*#' "$1" 2>/dev/null; }
# Clearly-mutating commands (short ambiguous words like cp/mv/dd are loop vars
# here, so we match the unambiguous mutators + a redirect-to-file or `tee`).
tests_run=$((tests_run+1)); if code_only "${PANEL}" | grep -qE '\b(rm|rmdir|mkdir|chmod|chown|truncate)\b|[[:space:]]tee[[:space:]]'; then _fail "panel-read uses a mutating command"; else _pass "panel-read uses NO mutating file command"; fi
tests_run=$((tests_run+1)); if code_only "${PANEL}" | grep -qE 'docker[[:space:]]+(run|rm|stop|start|up|down|exec|compose|create|kill|restart)'; then _fail "panel-read runs a mutating docker verb"; else _pass "panel-read runs only read-only docker (stats/info)"; fi
tests_run=$((tests_run+1)); if code_only "${PANEL}" | grep -qE '\beval\b'; then _fail "panel-read uses eval"; else _pass "panel-read never uses eval (code)"; fi

# ===========================================================================
section "BRIDGE — read actions map to panel-read.sh, classified read-only (dry-run)"
# ---------------------------------------------------------------------------
TMPRLOG="$(mktemp 2>/dev/null || echo "${SCRIPT_DIR}/.rdlog.$$")"
run_rd() { OUTR="$(BOT_EXEC_DRYRUN=1 TELEGRAM_BOT_EXEC_LOG="${TMPRLOG}" bash "${EXEC}" "$@" 2>&1)"; RCR=$?; }
for a in monitor_metrics monitor_alerts backup_status seo_audits prospects_list; do
  run_rd "${a}"
  ok "read action ${a} accepted" test "${RCR}" -eq 0
  has "${a} maps to panel-read.sh" "${OUTR}" "scripts/panel-read.sh ${a}"
  has "${a} is read-only" "${OUTR}" "CLASS=readonly"
done
run_rd monitor_metrics extra; ok "read action rejects an argument" test "${RCR}" -eq 2
rm -f "${TMPRLOG}"

# ===========================================================================
section "CROSS-CHECK — read actions read-only in BOTH layers (no drift)"
# ---------------------------------------------------------------------------
# Each new feed must be read-only in bridge-core.js AND bot-lib.sh (and never in a
# state-changing path) or one layer could mutate where the other expects a read.
if [[ -n "${NODE}" ]]; then
  for pair in "monitoring:monitor_metrics" "monitoring-alerts:monitor_alerts" "backup-status:backup_status" "growth-seo:seo_audits" "growth-prospects:prospects_list"; do
    api="${pair%%:*}"; bot="${pair##*:}"
    js_ro="$(cd "${API_DIR}" && "${NODE}" --input-type=module -e "import * as m from './lib/bridge-core.js'; console.log(m.READONLY_ACTIONS.includes('${api}'))" 2>/dev/null)"
    bash_ro="$(bash -c "source '${BOT_LIB}'; bot_is_readonly_action '${bot}' && echo true || echo false" 2>/dev/null)"
    bash_state="$(bash -c "source '${BOT_LIB}'; bot_is_state_action '${bot}' && echo true || echo false" 2>/dev/null)"
    tests_run=$((tests_run+1))
    if [[ "${js_ro}" == "true" && "${bash_ro}" == "true" && "${bash_state}" == "false" ]]; then
      _pass "read-only both layers: ${api} / ${bot}"
    else _fail "read-only DRIFT ${api}/${bot} — js_ro=${js_ro} bash_ro=${bash_ro} bash_state=${bash_state}"; fi
  done
else
  _skip "read-only cross-check (no node)"
fi
# NO NEW WRITE CAPABILITY: the panel-read actions are NOT in the command map and
# have NO state-changing path; bot-exec maps them ONLY to panel-read.sh.
tests_run=$((tests_run+1))
if grep -qE 'bot_run_(pi|project|restart)\b.*(monitor_metrics|monitor_alerts|backup_status|seo_audits|prospects_list)' "${EXEC}"; then
  _fail "a read action is wired to a state-changing runner"
else _pass "no read action reaches a state-changing runner"; fi

# ===========================================================================
section "INTEGRITY — scripts/config parse"
# ---------------------------------------------------------------------------
for f in scripts/control-api.sh scripts/bot-exec.sh scripts/bot-exec-generate.sh scripts/panel-read.sh scripts/lib/bot-lib.sh; do
  tests_run=$((tests_run+1))
  if bash -n "${PROJECT_ROOT}/${f}" 2>/dev/null; then _pass "syntax ok: ${f}"; else _fail "syntax error: ${f}"; fi
done
# The compose + Dockerfile + registry exist where the helper expects them.
for f in services/control-api/control-api.compose.yml services/control-api/Dockerfile \
         services/control-api/config-registry.json services/control-api/package.json; do
  tests_run=$((tests_run+1))
  [[ -f "${PROJECT_ROOT}/${f}" ]] && _pass "present: ${f}" || _fail "missing: ${f}"
done
# Caddy gained the api.<domain> block.
tests_run=$((tests_run+1))
if grep -q 'api.{$BASE_DOMAIN' "${PROJECT_ROOT}/services/proxy/Caddyfile"; then
  _pass "Caddyfile has the api.\${BASE_DOMAIN} block"
else _fail "Caddyfile is missing the api block"; fi
# The compose file publishes NO host ports.
tests_run=$((tests_run+1))
if ! grep -qE '^\s*ports:' "${PROJECT_ROOT}/services/control-api/control-api.compose.yml"; then
  _pass "control-api compose declares NO host ports"
else _fail "control-api compose unexpectedly publishes host ports"; fi

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
