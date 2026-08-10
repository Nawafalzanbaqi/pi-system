#!/usr/bin/env bash
# ===========================================================================
# pi-system — WEB ANALYTICS test harness
# ---------------------------------------------------------------------------
# Exercises the web-analytics MODULE + the analytics SERVICE entirely WITHOUT
# Docker (or a running Pi / Umami) — mirroring
# tests/{bot,ctl,startup,mem-budget,health-monitor,preflight}/run.sh. Pure logic +
# the real on-disk files; it NEVER mutates the repo (no generation into the live
# tree — full generation is the operator's sandbox VERIFY step).
#
# Coverage (each maps to a real way this feature could go wrong):
#   * MANIFEST          -> module.manifest is valid + honours the MODULE CONTRACT
#                          (frontend-only base_compatible, no db, no creds, env list)
#   * ENV-GATING        -> lib/analytics.js: snippet config is present ONLY when both
#                          ANALYTICS_* are set (the gate the whole feature hinges on)
#   * FILE PLACEMENT    -> per-base files land at the right path; it ADDS a root
#                          template (cooperates) and does NOT replace a root layout
#   * SNIPPET SHAPE     -> Analytics.jsx is env-gated, uses next/script + the umami
#                          website-id attr, and loads ONLY the self-hosted tracker
#   * PRIVACY           -> no Google Analytics / third-party tracker anywhere
#   * SERVICE COMPOSE   -> analytics.compose.yml: profile-gated, internal+proxy, NO
#                          host ports, isolated DB + own volume, pinned (not latest)
#   * MODULE COMPOSE    -> per-base fragments merge ANALYTICS_* env only (no new
#                          container, no host ports)
#   * WIRING            -> Caddy block, .env.example section, helper script, presets
#
# Usage:   ./tests/analytics/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MOD="${PROJECT_ROOT}/templates/modules/web-analytics"
MF="${MOD}/module.manifest"
SVC="${PROJECT_ROOT}/services/analytics/analytics.compose.yml"
HELPER="${PROJECT_ROOT}/scripts/analytics.sh"
CADDY="${PROJECT_ROOT}/services/proxy/Caddyfile"
ENVX="${PROJECT_ROOT}/.env.example"

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

check() { tests_run=$((tests_run+1)); if [[ "$2" == "$3" ]]; then _pass "$1"; else _fail "$1 — expected [$3], got [$2]"; fi; }
ok()    { tests_run=$((tests_run+1)); if "${@:2}"; then _pass "$1"; else _fail "$1 (expected success)"; fi; }
no()    { tests_run=$((tests_run+1)); if "${@:2}"; then _fail "$1 (expected failure)"; else _pass "$1"; fi; }
exists(){ tests_run=$((tests_run+1)); if [[ -f "$2" ]]; then _pass "$1"; else _fail "$1 — missing $2"; fi; }
absent(){ tests_run=$((tests_run+1)); if [[ ! -e "$2" ]]; then _pass "$1"; else _fail "$1 — unexpectedly present: $2"; fi; }
# fhas NAME FILE NEEDLE  /  fhasnt NAME FILE NEEDLE  (fixed-string grep over a file)
fhas()  { tests_run=$((tests_run+1)); if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then _pass "$1"; else _fail "$1 — [$2] missing [$3]"; fi; }
fhasnt(){ tests_run=$((tests_run+1)); if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then _fail "$1 — [$2] unexpectedly has [$3]"; else _pass "$1"; fi; }

# Manifest reader matching the generator's plain-shell parser.
mget() { local file="$1" key="$2" line val; line="$(grep -E "^[[:space:]]*${key}:[[:space:]]*" "${file}" 2>/dev/null | head -n1 || true)"; [[ -z "${line}" ]] && { printf ''; return 0; }; val="${line#*:}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"; printf '%s' "${val}"; }
contains_word() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PY=""; command -v python  >/dev/null 2>&1 && PY="$(command -v python)"
[[ -z "${PY}" ]] && command -v python3 >/dev/null 2>&1 && PY="$(command -v python3)"
NODE=""; command -v node >/dev/null 2>&1 && NODE="$(command -v node)"

# Run a python snippet that loads a YAML compose file as `d`; the snippet must
# print "OK" on success or "FAIL: ..." on failure. Echoes the snippet's output.
pyyaml() { # pyyaml <file> <python-body>
  "${PY}" - "$1" <<PYEOF 2>&1
import sys
try:
    import yaml
except Exception as e:
    print("NOYAML"); sys.exit(0)
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
svcs = d.get("services", {}) or {}
$2
PYEOF
}

# ===========================================================================
section "MANIFEST — module.manifest honours the MODULE CONTRACT"
# ---------------------------------------------------------------------------
exists "module.manifest exists" "${MF}"
check "name is web-analytics"            "$(mget "${MF}" name)"                 "web-analytics"
check "status implemented"               "$(mget "${MF}" status)"               "implemented"
check "database none"                    "$(mget "${MF}" database)"             "none"
check "external_credentials none"        "$(mget "${MF}" external_credentials)" "none"
check "files = files"                    "$(mget "${MF}" files)"                "files"
check "compose = compose"                "$(mget "${MF}" compose)"              "compose"
check "caddy_routes none"                "$(mget "${MF}" caddy_routes)"         "none"

BC="$(mget "${MF}" base_compatible)"; BCN="${BC//,/ }"
ok  "base_compatible includes nextjs-app" contains_word nextjs-app "${BCN}"
ok  "base_compatible includes fullstack"  contains_word fullstack  "${BCN}"
no  "base_compatible EXCLUDES dotnet-api (frontend-only)" contains_word dotnet-api "${BCN}"

ENVLIST="$(mget "${MF}" env)"; ENVLIST="${ENVLIST//,/ }"
ok  "env declares ANALYTICS_SCRIPT_URL" contains_word ANALYTICS_SCRIPT_URL "${ENVLIST}"
ok  "env declares ANALYTICS_SITE_ID"    contains_word ANALYTICS_SITE_ID    "${ENVLIST}"
# env.example mirrors the manifest env list (empty templates only — no values).
exists "env.example exists" "${MOD}/env.example"
fhas  "env.example has ANALYTICS_SCRIPT_URL=" "${MOD}/env.example" "ANALYTICS_SCRIPT_URL="
fhas  "env.example has ANALYTICS_SITE_ID="    "${MOD}/env.example" "ANALYTICS_SITE_ID="

# ===========================================================================
section "ENV-GATING — snippet config present ONLY when configured (lib logic)"
# ---------------------------------------------------------------------------
LIB="${MOD}/files/nextjs-app/lib/analytics.js"
exists "lib/analytics.js exists" "${LIB}"
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  GATE_OUT="$("${NODE}" --input-type=module -e '
    import { pathToFileURL } from "node:url";
    const { analyticsConfig, isAnalyticsEnabled } = await import(pathToFileURL(process.argv[1]).href);
    const both  = analyticsConfig({ ANALYTICS_SCRIPT_URL: "https://a.example/script.js", ANALYTICS_SITE_ID: "id-123" });
    const noUrl = analyticsConfig({ ANALYTICS_SITE_ID: "id-123" });
    const noId  = analyticsConfig({ ANALYTICS_SCRIPT_URL: "https://a.example/script.js" });
    const empty = analyticsConfig({});
    const ws    = analyticsConfig({ ANALYTICS_SCRIPT_URL: "   ", ANALYTICS_SITE_ID: "  " });
    if (!both || both.siteId !== "id-123" || both.scriptUrl !== "https://a.example/script.js") { console.log("FAIL:both"); process.exit(0); }
    if (noUrl !== null || noId !== null || empty !== null || ws !== null) { console.log("FAIL:gate"); process.exit(0); }
    if (isAnalyticsEnabled({}) !== false) { console.log("FAIL:enabledEmpty"); process.exit(0); }
    if (isAnalyticsEnabled({ ANALYTICS_SCRIPT_URL: "x", ANALYTICS_SITE_ID: "y" }) !== true) { console.log("FAIL:enabledBoth"); process.exit(0); }
    console.log("GATE_OK");
  ' "${LIB}" 2>&1)"
  if [[ "${GATE_OUT}" == *GATE_OK* ]]; then _pass "analyticsConfig: config iff BOTH vars set; null otherwise (incl. whitespace)"
  else _fail "env-gating decision wrong — ${GATE_OUT}"; fi
else
  _skip "env-gating decision (node not available)"
fi
# trackEvent helper exists (custom events) and is a safe no-op without window.
fhas "lib exports trackEvent (custom events)" "${LIB}" "export function trackEvent"
fhas "trackEvent guards on window"            "${LIB}" "typeof window"

# ===========================================================================
section "FILE PLACEMENT — per-base subtrees; cooperates (no layout replace)"
# ---------------------------------------------------------------------------
for base in nextjs-app fullstack; do
  if [[ "${base}" == "fullstack" ]]; then root="${MOD}/files/fullstack/frontend"; else root="${MOD}/files/nextjs-app"; fi
  exists "${base}: app/template.jsx"         "${root}/app/template.jsx"
  exists "${base}: components/Analytics.jsx" "${root}/components/Analytics.jsx"
  exists "${base}: lib/analytics.js"         "${root}/lib/analytics.js"
  # COOPERATION: it must NOT ship/replace a root layout (that would fight i18n/base).
  absent "${base}: ships NO root app/layout.jsx (nests, never replaces)" "${root}/app/layout.jsx"
  # template wraps children AND renders the analytics component.
  fhas "${base}: template renders {children}" "${root}/app/template.jsx" "{children}"
  fhas "${base}: template renders <Analytics" "${root}/app/template.jsx" "<Analytics"
done
# frontend-only: there must be NO dotnet-api files subtree.
absent "no dotnet-api files subtree (frontend-only)" "${MOD}/files/dotnet-api"

# ===========================================================================
section "SNIPPET SHAPE + PRIVACY — env-gated umami tracker, self-hosted only"
# ---------------------------------------------------------------------------
AN="${MOD}/files/nextjs-app/components/Analytics.jsx"
exists "Analytics.jsx exists" "${AN}"
fhas  "uses next/script (single, de-duped load)" "${AN}" "next/script"
fhas  "imports the env gate (analyticsConfig)"   "${AN}" "analyticsConfig"
fhas  "env-gate: returns null when unconfigured" "${AN}" "return null"
fhas  "emits the umami website-id attribute"     "${AN}" "data-website-id"
fhas  "tracker src comes from config (env)"      "${AN}" "cfg.scriptUrl"
# PRIVACY: no third-party / Google trackers anywhere in the module.
for needle in google-analytics googletagmanager gtag.js "gtag(" connect.facebook.net; do
  tests_run=$((tests_run+1))
  if grep -rqiF -- "${needle}" "${MOD}" 2>/dev/null; then _fail "third-party tracker found in module: ${needle}"; else _pass "no third-party tracker: ${needle}"; fi
done

# ===========================================================================
section "SERVICE COMPOSE — profile-gated, internal/proxy, no ports, isolated DB"
# ---------------------------------------------------------------------------
exists "analytics.compose.yml exists" "${SVC}"
if [[ -n "${PY}" ]]; then
  OUT="$(pyyaml "${SVC}" '
err = []
names = set(svcs.keys())
if names != {"umami", "umami-db"}: err.append(f"services={names}")
for n, s in svcs.items():
    if "ports" in s: err.append(n + " has host ports")
    if s.get("profiles") != ["analytics"]: err.append(n + " not profile-gated [analytics]")
    if s.get("security_opt") != ["no-new-privileges:true"]: err.append(n + " missing no-new-privileges")
    if s.get("restart") != "unless-stopped": err.append(n + " restart not unless-stopped")
    img = s.get("image", "")
    if img.endswith(":latest") or (img and ":" not in img.split("/")[-1]): err.append(n + " image not pinned: " + img)
# umami on BOTH networks; umami-db internal-only
if set(svcs["umami"].get("networks", [])) != {"internal", "proxy"}: err.append("umami networks wrong")
if svcs["umami-db"].get("networks", []) != ["internal"]: err.append("umami-db not internal-only")
# isolated, dedicated DB volume
vols = d.get("volumes", {}) or {}
if "umami_db_data" not in vols: err.append("missing umami_db_data volume")
if "umami_db_data" not in str(svcs["umami-db"].get("volumes", [])): err.append("umami-db not using its volume")
# credentials come from env (no literal secret), db type set
env = svcs["umami"].get("environment", {})
if "${ANALYTICS_APP_SECRET}" not in str(env.get("APP_SECRET", "")): err.append("APP_SECRET not from env")
if "${ANALYTICS_DB_PASSWORD}" not in str(env.get("DATABASE_URL", "")): err.append("DATABASE_URL not from env")
print("OK" if not err else "FAIL: " + "; ".join(err))
')"
  case "${OUT}" in
    *OK*)     tests_run=$((tests_run+1)); _pass "service compose invariants (profile/ports/networks/volume/secrets)" ;;
    *NOYAML*) _skip "service compose invariants (PyYAML not available)" ;;
    *)        tests_run=$((tests_run+1)); _fail "service compose invariants — ${OUT}" ;;
  esac
  # image is the pinned Umami tag (sanity: postgresql-v2 line, never latest)
  fhas  "umami image pinned to a postgresql-v2.* tag" "${SVC}" "ghcr.io/umami-software/umami:postgresql-v2.20.2"
  fhasnt "umami image is NOT :latest"                 "${SVC}" "umami:latest"
else
  _skip "service compose invariants (python not available)"
fi

# ===========================================================================
section "MODULE COMPOSE — per-base env-merge only (no container, no ports)"
# ---------------------------------------------------------------------------
declare -A WEBSVC=( [nextjs-app]="__PROJECT_NAME__" [fullstack]="__PROJECT_NAME__-web" )
for base in nextjs-app fullstack; do
  frag="${MOD}/compose/${base}.compose.yml"
  exists "${base}: compose fragment exists" "${frag}"
  if [[ -n "${PY}" ]]; then
    OUT="$(WANT="${WEBSVC[$base]}" pyyaml "${frag}" '
import os
err = []
want = os.environ.get("WANT")
if list(svcs.keys()) != [want]: err.append(f"services={list(svcs.keys())} (want only {want})")
s = list(svcs.values())[0] if svcs else {}
if "ports" in s: err.append("has host ports")
if "image" in s or "build" in s: err.append("declares a new container (image/build)")
env = s.get("environment", {})
if "ANALYTICS_SCRIPT_URL" not in env or "ANALYTICS_SITE_ID" not in env: err.append(f"env missing analytics keys: {list(env.keys())}")
print("OK" if not err else "FAIL: " + "; ".join(err))
')"
    case "${OUT}" in
      *OK*)     tests_run=$((tests_run+1)); _pass "${base}: merges ANALYTICS_* into ${WEBSVC[$base]} only (no container/ports)" ;;
      *NOYAML*) _skip "${base}: module compose invariants (PyYAML not available)" ;;
      *)        tests_run=$((tests_run+1)); _fail "${base}: module compose invariants — ${OUT}" ;;
    esac
  else
    _skip "${base}: module compose invariants (python not available)"
  fi
done

# ===========================================================================
section "WIRING — Caddy, .env.example, helper script, presets, discovery"
# ---------------------------------------------------------------------------
# Caddy: analytics dashboard subdomain -> umami:3000, env-driven, no host ports.
fhas "Caddyfile has analytics.{\$BASE_DOMAIN}" "${CADDY}" "analytics.{\$BASE_DOMAIN:localhost}"
fhas "Caddyfile proxies umami:3000"            "${CADDY}" "reverse_proxy umami:3000"
# .env.example: ANALYTICS section + the two service secrets.
fhas ".env.example has ANALYTICS section"      "${ENVX}" "ANALYTICS (web analytics — Umami)"
fhas ".env.example has ANALYTICS_DB_PASSWORD"  "${ENVX}" "ANALYTICS_DB_PASSWORD="
fhas ".env.example has ANALYTICS_APP_SECRET"   "${ENVX}" "ANALYTICS_APP_SECRET="
# Helper script: syntax + arg validation + profile/services.
tests_run=$((tests_run+1)); if bash -n "${HELPER}" 2>/dev/null; then _pass "analytics.sh syntax ok"; else _fail "analytics.sh syntax error"; fi
fhas "analytics.sh uses the analytics profile" "${HELPER}" 'PROFILE="analytics"'
fhas "analytics.sh owns umami + umami-db"      "${HELPER}" 'SERVICES="umami umami-db"'
ok   "analytics.sh rejects a bad action" bash -c 'cd "'"${PROJECT_ROOT}"'" && ! ./scripts/analytics.sh bogus >/dev/null 2>&1'
# Presets that should compose web-analytics (optional, but listed).
fhas "company-site preset lists web-analytics" "${PROJECT_ROOT}/templates/presets/company-site/preset.manifest" "web-analytics"
fhas "ecommerce preset lists web-analytics"    "${PROJECT_ROOT}/templates/presets/ecommerce/preset.manifest"    "web-analytics"
# Generator discovery: an implemented module is found by scanning manifests.
tests_run=$((tests_run+1))
FOUND=""
for m in "${PROJECT_ROOT}"/templates/modules/*/module.manifest; do
  [[ "$(mget "${m}" status)" == "implemented" ]] || continue
  [[ "$(mget "${m}" name)" == "web-analytics" ]] && FOUND=1
done
[[ -n "${FOUND}" ]] && _pass "generator discovers web-analytics as implemented" || _fail "web-analytics not discovered as implemented"

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
