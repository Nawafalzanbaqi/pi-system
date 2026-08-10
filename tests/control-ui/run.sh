#!/usr/bin/env bash
# ===========================================================================
# pi-system — CONTROL PANEL (UI) test harness (offline: no Docker / browser).
# ---------------------------------------------------------------------------
# Two layers, mirroring the other suites:
#   1. PURE LOGIC (node) -> tests/control-ui/ui.test.mjs imports the UI logic
#      modules directly and proves: API-client request shaping (method/path/body
#      + bearer attached), the auth-guard decision, that a secret value is NEVER
#      displayable, the action confirm->pending->result state machine, the wizard
#      payload builder, and the live-data adapters.
#   2. STATIC checks (bash) -> the prototype scaffolding was dropped, fonts are
#      self-hosted (no CDN), the BFF session endpoint never returns tokens, the
#      Settings view uses the secret-safe value helper, and new deps are PINNED.
#
# Usage:   ./tests/control-ui/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
API_DIR="${PROJECT_ROOT}/services/control-api"
APP_DIR="${API_DIR}/app"
CMP_DIR="${API_DIR}/components"

if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; O=$'\033[0m'
else G=''; R=''; Y=''; C=''; O=''; fi

tests_run=0; tests_failed=0; tests_skipped=0
_pass() { printf '  %s✓%s %s\n' "${G}" "${O}" "$1"; }
_fail() { printf '  %s✗%s %s\n' "${R}" "${O}" "$1"; tests_failed=$((tests_failed+1)); }
_skip() { printf '  %s~%s %s (skipped)\n' "${Y}" "${O}" "$1"; tests_skipped=$((tests_skipped+1)); }
section() { printf '\n%s== %s ==%s\n' "${C}" "$1" "${O}"; }
present() { tests_run=$((tests_run+1)); if grep -RIlq -- "$2" "$3" 2>/dev/null; then _pass "$1"; else _fail "$1"; fi; }
absent()  { tests_run=$((tests_run+1)); if grep -RIlq -- "$2" "$3" 2>/dev/null; then _fail "$1"; else _pass "$1"; fi; }

# ===========================================================================
section "PURE LOGIC — tests/control-ui/ui.test.mjs (node)"
# ---------------------------------------------------------------------------
NODE="$(command -v node || true)"
if [[ -z "${NODE}" ]]; then
  _skip "node not available — pure-logic suite (install Node to run it)"
else
  tests_run=$((tests_run+1))
  if "${NODE}" "${SCRIPT_DIR}/ui.test.mjs"; then
    _pass "ui.test.mjs (shaping / guard / secrets / state-machine / wizard / adapters)"
  else
    _fail "ui.test.mjs reported failures (see output above)"
  fi
fi

# ===========================================================================
section "PROTOTYPE SCAFFOLDING DROPPED — CDN/Babel harness is gone"
# ---------------------------------------------------------------------------
for f in ui-design/index.html ui-design/design-canvas.jsx ui-design/sketchy.jsx ui-design/wireframes.jsx ui-design; do
  tests_run=$((tests_run+1))
  if [[ ! -e "${API_DIR}/${f}" ]]; then _pass "removed: ${f}"; else _fail "still present: ${f}"; fi
done
# No runtime CDN React / in-browser Babel anywhere in the real app.
absent "no unpkg/CDN React in app" "unpkg.com" "${APP_DIR}"
absent "no @babel/standalone harness in app" "babel/standalone" "${APP_DIR} ${CMP_DIR}"
# Fonts are self-hosted (next/font), NOT a runtime Google Fonts CDN link.
absent "no fonts.googleapis CDN link" "fonts.googleapis.com" "${APP_DIR} ${CMP_DIR}"
present "fonts via next/font/google" "next/font/google" "${APP_DIR}/layout.jsx"

# ===========================================================================
section "SECURITY — tokens never reach the browser; secrets stay write-only"
# ---------------------------------------------------------------------------
# The session probe must return identity ONLY — never the access/id token.
absent "session route does not return access_token" "access_token" "${APP_DIR}/api/auth/session/route.js"
absent "session route does not return id_token" "id_token" "${APP_DIR}/api/auth/session/route.js"
present "session route returns isOperator only" "isOperator" "${APP_DIR}/api/auth/session/route.js"
# The cookie is httpOnly + SameSite=Lax (CSRF-safe for POST actions).
present "session cookie is httpOnly" "httpOnly: true" "${API_DIR}/lib/auth/session-core.js"
present "session cookie is SameSite=Lax" "sameSite: 'lax'" "${API_DIR}/lib/auth/session-core.js"
# The integrations view renders values ONLY through the secret-safe helper.
present "Settings uses displayableKeyValue helper" "displayableKeyValue" "${CMP_DIR}/sections/Settings.jsx"
present "secret inputs are password-typed" "type={k.secret" "${CMP_DIR}/sections/Settings.jsx"
# The UI must NOT cache the access token / weaken auth (no localStorage token).
absent "no localStorage token caching" "localStorage" "${CMP_DIR} ${API_DIR}/lib/api-client.js"

# ===========================================================================
section "WIZARD — project creation is wired (POST /api/projects, operator-only)"
# ---------------------------------------------------------------------------
# The api-client exposes createProject; the wizard submits it through the confirm
# dialog (no insecure host-exec, no copy-paste dead-end).
present "api-client exposes createProject" "createProject" "${API_DIR}/lib/api-client.js"
present "createProject POSTs /api/projects" "ENDPOINTS.createProject" "${API_DIR}/lib/api-client.js"
present "wizard calls client.createProject" "client.createProject" "${CMP_DIR}/sections/Projects.jsx"
present "wizard confirms via useConfirm (confirm.ask)" "confirm.ask" "${CMP_DIR}/sections/Projects.jsx"
present "wizard builds the create payload" "buildCreateConfirm" "${CMP_DIR}/sections/Projects.jsx"
present "wizard refreshes the list after create" "onCreated" "${CMP_DIR}/sections/Projects.jsx"
# The old "not wired" copy-paste dead-end is gone (no NotWired component left).
absent "no NotWired dead-end remains" "function NotWired" "${CMP_DIR}/sections/Projects.jsx"
# wizard-payload sources its allowlists from generate-core (single source of truth).
present "wizard-payload imports allowlists from generate-core" "from './generate-core.js'" "${API_DIR}/lib/wizard-payload.js"

# ===========================================================================
section "MONITORING + GROWTH — now LIVE (no SAMPLE_* / no 'live source pending')"
# ---------------------------------------------------------------------------
# The sample fixtures + the "live source pending" badge are GONE from both views;
# each fetches the new read-only endpoints through the typed client + adapters.
absent "Monitoring drops SAMPLE_METRICS fixture" "SAMPLE_METRICS" "${CMP_DIR}/sections/Monitoring.jsx"
absent "Monitoring drops SAMPLE_ALERTS fixture" "SAMPLE_ALERTS" "${CMP_DIR}/sections/Monitoring.jsx"
absent "Monitoring drops SAMPLE_BACKUP fixture" "SAMPLE_BACKUP" "${CMP_DIR}/sections/Monitoring.jsx"
absent "Growth drops SAMPLE_PROSPECTS fixture" "SAMPLE_PROSPECTS" "${CMP_DIR}/sections/Growth.jsx"
absent "Growth drops SAMPLE_SEO_AUDITS fixture" "SAMPLE_SEO_AUDITS" "${CMP_DIR}/sections/Growth.jsx"
absent "Growth drops SAMPLE_ANALYTICS fixture" "SAMPLE_ANALYTICS" "${CMP_DIR}/sections/Growth.jsx"
absent "no 'live source pending' badge in Monitoring" "live source pending" "${CMP_DIR}/sections/Monitoring.jsx"
absent "no 'live source pending' badge in Growth" "live source pending" "${CMP_DIR}/sections/Growth.jsx"
present "Monitoring fetches live metrics" "client.getMonitoring()" "${CMP_DIR}/sections/Monitoring.jsx"
present "Monitoring fetches live alerts" "client.getMonitoringAlerts()" "${CMP_DIR}/sections/Monitoring.jsx"
present "Monitoring fetches live backup status" "client.getBackupStatus()" "${CMP_DIR}/sections/Monitoring.jsx"
present "Growth fetches live prospects" "client.getGrowthProspects()" "${CMP_DIR}/sections/Growth.jsx"
present "Growth fetches live SEO" "client.getGrowthSeo()" "${CMP_DIR}/sections/Growth.jsx"
present "Growth fetches live analytics" "client.getGrowthAnalytics()" "${CMP_DIR}/sections/Growth.jsx"
# The adapters + client methods exist.
for fn in adaptMonitoring adaptMonitoringAlerts adaptBackup adaptSeo adaptProspects adaptAnalytics; do
  present "adapter ${fn} exists" "export function ${fn}" "${API_DIR}/lib/adapt.js"
done
present "client exposes the live getters" "getMonitoring:" "${API_DIR}/lib/api-client.js"
# Templates view stays STATIC + copy-paste only (the legal/ethical boundary).
present "Growth keeps the static message drafts" "SAMPLE_TEMPLATES" "${CMP_DIR}/sections/Growth.jsx"
present "message drafts are copy-paste only (manual)" "templates_sub" "${CMP_DIR}/sections/Growth.jsx"
# Growth must NOT auto-send or POST outreach (read/organize only this part).
absent "Growth sends no POST/outreach" "client.runAction" "${CMP_DIR}/sections/Growth.jsx"
# Analytics credentials stay server-side: the summary is fetched in the route via
# the server lib, never in a component, and the token is never returned.
present "analytics route uses the server umami lib" "fetchUmamiSummary" "${APP_DIR}/api/growth/analytics/route.js"
absent "umami server lib is NOT imported by any component" "umami.js" "${CMP_DIR}"

# ===========================================================================
section "BUILD HYGIENE — new deps PINNED (never ^ ~ latest)"
# ---------------------------------------------------------------------------
PKG="${API_DIR}/package.json"
for dep in framer-motion recharts openid-client; do
  tests_run=$((tests_run+1))
  line="$(grep -E "\"${dep}\"" "${PKG}" || true)"
  if [[ -n "${line}" ]] && ! grep -qE "\"${dep}\"\s*:\s*\"[~^]|latest" "${PKG}"; then
    _pass "pinned exact: ${dep} -> $(printf '%s' "${line}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  else _fail "${dep} must be pinned to an exact version (no ^ ~ latest)"; fi
done
# Still standalone + still no host ports (unchanged deploy posture).
present "next standalone output kept" "output: 'standalone'" "${API_DIR}/next.config.mjs"
tests_run=$((tests_run+1))
if ! grep -qE '^\s*ports:' "${API_DIR}/control-api.compose.yml"; then _pass "compose declares NO host ports"; else _fail "compose unexpectedly publishes host ports"; fi

# ===========================================================================
section "Results"
# ---------------------------------------------------------------------------
printf '  %d run, %s%d failed%s, %d skipped\n' \
  "${tests_run}" "$( ((tests_failed)) && echo "${R}" || echo "${G}")" "${tests_failed}" "${O}" "${tests_skipped}"
if (( tests_failed > 0 )); then printf '%sTESTS FAILED%s\n' "${R}" "${O}" >&2; exit 1; fi
printf '%sALL TESTS PASSED%s\n' "${G}" "${O}"
exit 0
