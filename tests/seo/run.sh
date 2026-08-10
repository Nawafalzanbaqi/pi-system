#!/usr/bin/env bash
# ===========================================================================
# pi-system — SEO & SITE-QUALITY test harness
# ---------------------------------------------------------------------------
# Exercises the SEO audit ENGINE + the seo-toolkit MODULE + the seo SERVICE
# entirely WITHOUT Docker, network, a browser, or any AI call — mirroring
# tests/{analytics,bot,ctl,startup,mem-budget,health-monitor,preflight}/run.sh.
# Pure logic + the real on-disk files; it never mutates the repo (it writes only
# under a throwaway temp dir for the store test).
#
# Coverage (each maps to a real way this feature could go wrong):
#   * MANIFEST        -> seo-toolkit module.manifest honours the MODULE CONTRACT
#   * RULES           -> rules.js: correct, prioritised findings on fixture audits
#                        (bad/good/unreachable/lighthouse) — the FREE default path
#   * VERDICT         -> verdict.js: weighted overall score + tier + top-3 findings +
#                        one-line opportunity, deterministic; strong=excellent/100,
#                        weak=poor, unreachable=0; exact 5-category weighting; and
#                        wired into buildAudit so every audit carries audit.verdict
#   * SECURITY        -> security.js: response-header score + client-facing findings;
#                        hardened site = 100/0 findings, weak http site = low score +
#                        critical no-https + csp/cookie findings; Fetch-Headers forEach
#                        accepted with names lowercased. Wired into the audit: probe.js
#                        sets checks.security, scoring.js adds a 5th category, rules.js
#                        appends the findings (still sorted critical-first).
#   * PERFORMANCE     -> probe.js perfSignals: browser-free signals parsed from the
#                        HTML (render-blocking <script src>/<link stylesheet>, images
#                        without width/height, loading=lazy, preconnect/preload, inline
#                        CSS/JS weight) folded into performanceScore + new rules; a fast
#                        fixture stays 100/no findings, a slow one drops + flags issues
#   * AI-GATING       -> ai.js: rule-based when no key; the RICHER enrichment (a
#                        prioritised, deduplicated, effort-tagged action plan merging
#                        rule + AI items, plus a bilingual ar/en executive summary)
#                        selected ONLY when a key is present; via a MOCKED fetch — NO
#                        real call. Proves the inert path makes zero fetches, the AI
#                        never overwrites the deterministic findings, AI items dedup
#                        against rule findings, and a non-JSON/erroring reply degrades
#                        to the deterministic fallback summary + rule-based plan.
#   * PROSPECT-REPORT -> report.js buildProspectReport: a pure, deterministic, BILINGUAL
#                        (ar RTL-first / en) client-facing report — header, overall
#                        verdict + tier, the 5 category scores table, top prioritised
#                        findings (critical-first) with plain recommendations, the AI
#                        executive summary when present, and a footer; strong/weak/
#                        unreachable audits render the right structure in both locales
#   * PDF-EXPORT      -> md-to-html.js: the PURE, dependency-free Markdown->HTML core of
#                        the OPTIONAL PDF export (headings/lists/blockquotes/GFM tables/
#                        inline + RTL passthrough, HTML-escaped, deterministic, A4 print
#                        CSS + dir detection); AND pdf-export.js: the OFF-BY-DEFAULT
#                        renderer seam degrades to HTML/Markdown when absent, emits a PDF
#                        only via an INJECTED renderer (no real lib/network); AND store.js
#                        writeReportArtifact/latestReport round-trip (temp dir)
#   * SITEMAP         -> bilingual sitemap + hreflang (and single-locale degrade)
#   * METADATA        -> buildMetadata canonical/hreflang per locale
#   * FILE PLACEMENT  -> per-base SEO assets at the right path; STRICTLY ADDITIVE
#                        (no layout/page/template/middleware replace -> no collisions)
#   * SERVICE COMPOSE -> seo.compose.yml: profile-gated, internal-only, NO host
#                        ports, mem limits, one-shot (restart "no" — no always-on
#                        browser), pinned build images, two services
#   * MODULE COMPOSE  -> per-base fragments merge SEO_* env only (no container/ports)
#   * BOOT PROFILES   -> the seo services are in NO boot profile (never always-on)
#   * STORE           -> store.js append/read/trend round-trips (temp dir)
#   * SSRF-GUARD      -> ssrf-guard.js: private/reserved IPv4+IPv6 + internal
#                        hostnames blocked, public allowed; scheme + credential
#                        policy; assertUrlAllowed DNS-rebinding defense via an
#                        INJECTED resolver (NO network) + the allow-private opt-in;
#                        AND probe.js wiring — probeUrl refuses a blocked initial URL
#                        and a 302->internal redirect, never fetching the bad host
#   * WIRING          -> .env.example, seo.sh + seo-lib + cron syntax/args, presets,
#                        generator discovery, sites example, engine package.json
#
# Usage:   ./tests/seo/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MOD="${PROJECT_ROOT}/templates/modules/seo-toolkit"
MF="${MOD}/module.manifest"
ENGINE="${PROJECT_ROOT}/services/seo/engine"
SVC="${PROJECT_ROOT}/services/seo/seo.compose.yml"
HELPER="${PROJECT_ROOT}/scripts/seo.sh"
LIB="${PROJECT_ROOT}/scripts/lib/seo-lib.sh"
CRON="${PROJECT_ROOT}/scripts/seo-install-cron.sh"
ENVX="${PROJECT_ROOT}/.env.example"
BOOTPROFILES="${PROJECT_ROOT}/infrastructure/boot-profiles.conf"
FIX="${SCRIPT_DIR}/fixtures"

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
fhas()  { tests_run=$((tests_run+1)); if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then _pass "$1"; else _fail "$1 — [$2] missing [$3]"; fi; }
fhasnt(){ tests_run=$((tests_run+1)); if [[ -f "$2" ]] && grep -qF -- "$3" "$2"; then _fail "$1 — [$2] unexpectedly has [$3]"; else _pass "$1"; fi; }

# Manifest reader matching the generator's plain-shell parser.
mget() { local file="$1" key="$2" line val; line="$(grep -E "^[[:space:]]*${key}:[[:space:]]*" "${file}" 2>/dev/null | head -n1 || true)"; [[ -z "${line}" ]] && { printf ''; return 0; }; val="${line#*:}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"; printf '%s' "${val}"; }
contains_word() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

PY=""; command -v python  >/dev/null 2>&1 && PY="$(command -v python)"
[[ -z "${PY}" ]] && command -v python3 >/dev/null 2>&1 && PY="$(command -v python3)"
NODE=""; command -v node >/dev/null 2>&1 && NODE="$(command -v node)"

pyyaml() { # pyyaml <file> <python-body>
  "${PY}" - "$1" <<PYEOF 2>&1
import sys
try:
    import yaml
except Exception:
    print("NOYAML"); sys.exit(0)
d = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
svcs = d.get("services", {}) or {}
$2
PYEOF
}

# Run a node ESM snippet, passing file paths as ARGV (NOT embedded in the code) so
# they resolve correctly on every platform — including Git-bash on Windows, which
# converts POSIX-looking path ARGUMENTS to native form but does not touch paths
# inside the -e string. Snippets import modules via pathToFileURL(process.argv[N])
# and read fixtures via readFileSync(process.argv[N]). $1 = snippet; $2.. = paths.
nodejs() { local body="$1"; shift; "${NODE}" --input-type=module -e "${body}" "$@" 2>&1; }

# ===========================================================================
section "MANIFEST — seo-toolkit module.manifest honours the MODULE CONTRACT"
# ---------------------------------------------------------------------------
exists "module.manifest exists" "${MF}"
check "name is seo-toolkit"        "$(mget "${MF}" name)"                 "seo-toolkit"
check "status implemented"         "$(mget "${MF}" status)"               "implemented"
check "database none"              "$(mget "${MF}" database)"             "none"
check "external_credentials none"  "$(mget "${MF}" external_credentials)" "none"
check "files = files"              "$(mget "${MF}" files)"                "files"
check "compose = compose"          "$(mget "${MF}" compose)"              "compose"
check "caddy_routes none"          "$(mget "${MF}" caddy_routes)"         "none"

BC="$(mget "${MF}" base_compatible)"; BCN="${BC//,/ }"
ok  "base_compatible includes nextjs-app" contains_word nextjs-app "${BCN}"
ok  "base_compatible includes fullstack"  contains_word fullstack  "${BCN}"
no  "base_compatible EXCLUDES dotnet-api (frontend-only)" contains_word dotnet-api "${BCN}"

ENVLIST="$(mget "${MF}" env)"; ENVLIST="${ENVLIST//,/ }"
ok  "env declares SEO_SITE_URL"  contains_word SEO_SITE_URL  "${ENVLIST}"
ok  "env declares SEO_SITE_NAME" contains_word SEO_SITE_NAME "${ENVLIST}"
ok  "env declares SEO_LOCALES"   contains_word SEO_LOCALES   "${ENVLIST}"
exists "env.example exists" "${MOD}/env.example"
fhas  "env.example has SEO_SITE_URL="  "${MOD}/env.example" "SEO_SITE_URL="
fhas  "env.example has SEO_SITE_NAME=" "${MOD}/env.example" "SEO_SITE_NAME="
fhas  "env.example has SEO_LOCALES="   "${MOD}/env.example" "SEO_LOCALES="

# ===========================================================================
section "RULES — deterministic recommendations on fixture audits (FREE path)"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [rulesP, badP, goodP, downP, lhP] = process.argv.slice(1);
    const { analyze, summarize } = await import(pathToFileURL(rulesP).href);
    const load = (p) => JSON.parse(readFileSync(p, "utf8"));

    const bad = analyze(load(badP));
    const badIds = bad.map(x=>x.id);
    const good = analyze(load(goodP));
    const down = analyze(load(downP));
    const lh = analyze(load(lhP));
    const lhIds = lh.map(x=>x.id);

    const errs = [];
    // BAD: must surface the key issues, critical-first ordering.
    for (const id of ["no-https","meta-description-missing","sitemap-missing","h1-missing","images-missing-alt","title-missing"])
      if (!badIds.includes(id)) errs.push("bad missing "+id);
    if (bad[0].priority !== "critical") errs.push("bad[0] not critical (got "+bad[0].priority+")");
    if (bad[0].id !== "no-https") errs.push("bad[0] not no-https (got "+bad[0].id+")");
    // ordering is non-decreasing priority weight
    const W={critical:0,high:1,medium:2,low:3};
    for (let i=1;i<bad.length;i++) if (W[bad[i].priority] < W[bad[i-1].priority]) errs.push("bad not sorted at "+i);
    const bc = summarize(bad);
    if (bc.critical < 1) errs.push("bad has no critical");

    // GOOD: zero findings.
    if (good.length !== 0) errs.push("good should have 0 findings, got "+good.length);

    // UNREACHABLE: exactly one finding, site-unreachable critical.
    if (down.length !== 1 || down[0].id !== "site-unreachable" || down[0].priority !== "critical")
      errs.push("unreachable wrong: "+JSON.stringify(down.map(x=>x.id+":"+x.priority)));

    // LIGHTHOUSE: Core Web Vitals findings fire (probe never produces these).
    for (const id of ["lcp-poor","cls-poor","tbt-poor"])
      if (!lhIds.includes(id)) errs.push("lighthouse missing "+id);

    // Every finding has the required shape.
    for (const x of [...bad,...lh]) {
      for (const k of ["id","priority","category","title","detail","recommendation"])
        if (!x[k]) errs.push("finding "+x.id+" missing "+k);
      if (!["critical","high","medium","low"].includes(x.priority)) errs.push("bad priority "+x.priority);
      if (!["performance","accessibility","best-practices","seo"].includes(x.category)) errs.push("bad category "+x.category);
    }
    console.log(errs.length ? "FAIL: "+errs.join("; ") : "RULES_OK ("+bad.length+" bad, "+good.length+" good, "+down.length+" down, "+lh.length+" lh)");
  ' "${ENGINE}/rules.js" "${FIX}/audit-bad.json" "${FIX}/audit-good.json" "${FIX}/audit-unreachable.json" "${FIX}/audit-lighthouse.json")"
  if [[ "${OUT}" == *RULES_OK* ]]; then _pass "rules: prioritised findings correct on bad/good/unreachable/lighthouse — ${OUT#*RULES_OK }"
  else _fail "rules logic wrong — ${OUT}"; fi
else
  _skip "rules logic (node not available)"
fi

# ===========================================================================
section "VERDICT — overall prospect roll-up: weighted score + tier + opportunity (engine/verdict.js)"
# ---------------------------------------------------------------------------
# Pure, offline: rolls the five category scores + the prioritised findings into ONE
# sales-angle verdict. A strong site -> excellent/100 with 0 findings; a weak site ->
# poor with the top fix surfaced as the opportunity; an unreachable site -> 0/poor with
# the single site-unreachable finding. Also pins the exact 5-category weighting math and
# proves buildAudit always attaches audit.verdict (recomputed for the lighthouse engine).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [verdictP, probeP, goodP, badP, downP] = process.argv.slice(1);
    const { computeVerdict, VERDICT_WEIGHTS } = await import(pathToFileURL(verdictP).href);
    const { buildAudit } = await import(pathToFileURL(probeP).href);
    const load = (p) => JSON.parse(readFileSync(p, "utf8"));
    const TIERS = ["excellent","good","fair","poor"];
    const errs = [];

    // Weights sum to 1.0 (the documented contract).
    const wsum = Object.values(VERDICT_WEIGHTS).reduce((a,b)=>a+b,0);
    if (Math.abs(wsum - 1) > 1e-9) errs.push("weights do not sum to 1 (got "+wsum+")");

    // Every verdict must have the documented, well-formed shape.
    const shape = (v, label) => {
      if (!v || typeof v !== "object") { errs.push(label+": no verdict object"); return; }
      if (!Number.isFinite(v.overall) || v.overall < 0 || v.overall > 100) errs.push(label+": overall out of range ("+v.overall+")");
      if (!TIERS.includes(v.tier)) errs.push(label+": bad tier "+v.tier);
      if (!Array.isArray(v.topFindings) || v.topFindings.length > 3) errs.push(label+": topFindings not an array of ≤3");
      if (typeof v.opportunity !== "string" || !v.opportunity) errs.push(label+": missing opportunity line");
      for (const fnd of v.topFindings)
        for (const k of ["id","priority","category","title","recommendation"])
          if (!fnd[k]) errs.push(label+": topFinding "+(fnd.id||"?")+" missing "+k);
    };

    // STRONG site -> excellent, perfect score, no findings.
    const strong = computeVerdict(load(goodP)); shape(strong, "strong");
    if (strong.overall !== 100) errs.push("strong overall != 100 (got "+strong.overall+")");
    if (strong.tier !== "excellent") errs.push("strong tier != excellent (got "+strong.tier+")");
    if (strong.topFindings.length !== 0) errs.push("strong should have 0 topFindings (got "+strong.topFindings.length+")");
    if (!/no major issues/i.test(strong.opportunity)) errs.push("strong opportunity wrong: "+strong.opportunity);

    // WEAK site -> poor, low score, the no-https critical surfaced as the opportunity.
    const weak = computeVerdict(load(badP)); shape(weak, "weak");
    if (weak.tier !== "poor") errs.push("weak tier != poor (got "+weak.tier+")");
    if (weak.overall >= 50) errs.push("weak overall too high (got "+weak.overall+")");
    if (weak.topFindings[0].id !== "no-https") errs.push("weak top finding != no-https (got "+weak.topFindings[0].id+")");
    if (!/https/i.test(weak.opportunity)) errs.push("weak opportunity should name the top fix: "+weak.opportunity);

    // UNREACHABLE site -> 0/poor, the single site-unreachable finding, urgent opportunity.
    const down = computeVerdict(load(downP)); shape(down, "down");
    if (down.overall !== 0) errs.push("down overall != 0 (got "+down.overall+")");
    if (down.tier !== "poor") errs.push("down tier != poor (got "+down.tier+")");
    if (down.topFindings.length !== 1 || down.topFindings[0].id !== "site-unreachable") errs.push("down topFindings wrong: "+JSON.stringify(down.topFindings.map(x=>x.id)));
    if (!/unreachable/i.test(down.opportunity)) errs.push("down opportunity wrong: "+down.opportunity);

    // EXACT weighting with all FIVE categories present (synthetic):
    // 80*.3 + 60*.25 + 50*.2 + 40*.15 + 20*.1 = 24+15+10+6+2 = 57 -> fair.
    const five = computeVerdict({ ok:true, scores:{ seo:80, performance:60, security:50, "best-practices":40, accessibility:20 }, checks:{} });
    if (five.overall !== 57) errs.push("5-category weighting wrong (expected 57, got "+five.overall+")");
    if (five.tier !== "fair") errs.push("5-category tier wrong (expected fair, got "+five.tier+")");

    // DETERMINISM: same audit in => byte-identical verdict out.
    if (JSON.stringify(computeVerdict(load(badP))) !== JSON.stringify(weak)) errs.push("computeVerdict not deterministic");

    // WIRING: buildAudit ALWAYS attaches a well-formed verdict.
    const built = buildAudit({ name:"w", url:"https://w.example.com", engine:"probe", timestamp:"2026-05-25T00:00:00.000Z", ok:true, status:200, metrics:{responseMs:100,htmlBytes:9000}, checks:{ https:true, title:{present:true,length:35}, metaDescription:{present:true,length:120}, h1:{count:1}, viewport:true, lang:"en", canonical:true, openGraph:{title:true,description:true,image:true}, imagesTotal:1, imagesMissingAlt:0, structuredData:true, robotsTxt:true, sitemapXml:true } });
    if (!built.verdict) errs.push("buildAudit did not attach audit.verdict");
    else shape(built.verdict, "built");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "VERDICT_OK (strong="+strong.overall+"/"+strong.tier+", weak="+weak.overall+"/"+weak.tier+", down="+down.overall+"/"+down.tier+", five="+five.overall+")");
  ' "${ENGINE}/verdict.js" "${ENGINE}/probe.js" "${FIX}/audit-good.json" "${FIX}/audit-bad.json" "${FIX}/audit-unreachable.json")"
  if [[ "${OUT}" == *VERDICT_OK* ]]; then _pass "verdict: weighted overall + tier + top-3 + opportunity; deterministic; wired into buildAudit — ${OUT#*VERDICT_OK }"
  else _fail "verdict logic wrong — ${OUT}"; fi
else
  _skip "verdict logic (node not available)"
fi

# ===========================================================================
section "SECURITY — response-header checks: score + client-facing findings (engine/security.js)"
# ---------------------------------------------------------------------------
# Pure, offline (no network, no browser): a well-hardened site scores 100 with zero
# findings; a weak http site (no security headers, leaky Server/X-Powered-By, insecure
# cookie) scores low with a CRITICAL no-https finding plus csp + cookie findings, all
# emitted critical-first; and a Fetch-Headers-LIKE forEach object is accepted with its
# header names lowercased (case-insensitive lookups).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [secP] = process.argv.slice(1);
    const { analyzeSecurity, securityScore, securityFindings, headersToObject } = await import(pathToFileURL(secP).href);
    const errs = [];
    const ids = (fs) => fs.map((x) => x.id);
    const W = { critical: 0, high: 1, medium: 2, low: 3 };

    // (1) WELL-HARDENED site over HTTPS. Headers arrive via a Fetch-Headers-LIKE object
    //     (forEach((value,key)=>...)) with MIXED-CASE names — proving forEach handling
    //     AND that names are lowercased for case-insensitive lookups.
    const hardened = { forEach(cb) {
      cb("max-age=63072000; includeSubDomains; preload", "Strict-Transport-Security");
      cb("default-src self; frame-ancestors none",        "Content-Security-Policy");
      cb("nosniff",                                       "X-Content-Type-Options");
      cb("DENY",                                          "X-Frame-Options");
      cb("strict-origin-when-cross-origin",               "Referrer-Policy");
      cb("camera=(), microphone=(), geolocation=()",      "Permissions-Policy");
    } };
    const hobj = headersToObject(hardened);
    if (!("strict-transport-security" in hobj)) errs.push("forEach value not captured (hsts)");
    if (!("content-security-policy" in hobj)) errs.push("forEach value not captured (csp)");
    if ("Strict-Transport-Security" in hobj) errs.push("header name NOT lowercased");
    const secGood = analyzeSecurity(hardened, { https: true });
    const goodScore = securityScore(secGood);
    if (goodScore !== 100) errs.push("hardened score != 100 (got " + goodScore + ")");
    const goodFindings = securityFindings({ checks: { security: secGood } });
    if (goodFindings.length !== 0) errs.push("hardened should have 0 findings, got " + goodFindings.length + ": " + ids(goodFindings).join(","));

    // (2) WEAK http site: no security headers, leaky Server / X-Powered-By, insecure cookie.
    const weak = {
      "server": "nginx/1.18.0",
      "x-powered-by": "PHP/8.1.2",
      "set-cookie": "sid=abc123; Path=/",
    };
    const secBad = analyzeSecurity(weak, { https: false });
    const badScore = securityScore(secBad);
    if (!(badScore < 50)) errs.push("weak score not low (got " + badScore + ")");
    const bad = securityFindings({ checks: { security: secBad } });
    const badIds = ids(bad);
    // CRITICAL no-https, plus csp + cookie findings (the headline talking points).
    if (!badIds.includes("security-no-https")) errs.push("weak missing security-no-https");
    const noHttps = bad.find((x) => x.id === "security-no-https");
    if (!noHttps || noHttps.priority !== "critical") errs.push("security-no-https not critical");
    if (!badIds.includes("security-no-csp")) errs.push("weak missing security-no-csp");
    if (!badIds.includes("security-insecure-cookies")) errs.push("weak missing security-insecure-cookies");
    // the leaky Server / X-Powered-By is also surfaced.
    if (!badIds.includes("security-version-disclosure")) errs.push("weak missing security-version-disclosure");
    // emitted critical-first (non-decreasing priority weight) — same discipline as rules.js.
    if (bad[0].priority !== "critical") errs.push("weak[0] not critical (got " + bad[0].priority + ")");
    for (let i = 1; i < bad.length; i++) if (W[bad[i].priority] < W[bad[i - 1].priority]) errs.push("weak not sorted at " + i);
    // every finding has the stable shape and the security category.
    for (const x of bad) {
      for (const k of ["id", "priority", "category", "title", "detail", "recommendation"]) if (!x[k]) errs.push("finding " + x.id + " missing " + k);
      if (x.category !== "security") errs.push("finding " + x.id + " category != security (" + x.category + ")");
    }

    // (3) Robustness: an absent/empty header set never throws — yields {} and the
    //     all-missing (fail-closed) shape that still produces findings.
    if (Object.keys(headersToObject(undefined)).length !== 0) errs.push("undefined headers not {}");
    const secEmpty = analyzeSecurity(undefined, { https: false });
    if (securityFindings({ checks: { security: secEmpty } }).length === 0) errs.push("empty headers produced no findings");

    console.log(errs.length ? "FAIL: " + errs.join("; ") : "SECURITY_OK (hardened " + goodScore + "/0 findings; weak " + badScore + "/" + bad.length + " findings)");
  ' "${ENGINE}/security.js")"
  if [[ "${OUT}" == *SECURITY_OK* ]]; then _pass "security: hardened=100/0 findings; weak=low score + critical no-https + csp/cookie; forEach lowercased — ${OUT#*SECURITY_OK }"
  else _fail "security logic wrong — ${OUT}"; fi
else
  _skip "security logic (node not available)"
fi

# ===========================================================================
section "PERFORMANCE — browser-free signals parsed from HTML (probe + scoring + rules)"
# ---------------------------------------------------------------------------
# Real fixture HTML through analyzeHtml (NO network/browser): a FAST page (deferred
# scripts, sized + lazy images, resource hints, tiny inline) yields all-good signals,
# a perfect performance score and no new perf findings; a SLOW page (6 blocking
# scripts + 4 stylesheets, unsized non-lazy images, no hints) yields a high
# render-blocking count, layout-shift + lazy + render-blocking findings, and a lower
# score. A synthetic huge-inline audit covers the inline-weight deduction + rule edge.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [probeP, scoringP, rulesP, fastP, slowP] = process.argv.slice(1);
    const { analyzeHtml } = await import(pathToFileURL(probeP).href);
    const { scoreAudit } = await import(pathToFileURL(scoringP).href);
    const { analyze } = await import(pathToFileURL(rulesP).href);
    const errs = [];
    const fast = analyzeHtml(readFileSync(fastP, "utf8"), { https: true });
    const slow = analyzeHtml(readFileSync(slowP, "utf8"), { https: true });
    const pf = fast.performance; const ps = slow.performance;

    // --- PARSING: the FAST page is well optimised.
    if (!pf) errs.push("fast: no checks.performance");
    if (pf.renderBlockingScripts !== 0) errs.push("fast renderBlockingScripts=" + pf.renderBlockingScripts + " (defer/module not excluded)");
    if (pf.stylesheets !== 1) errs.push("fast stylesheets=" + pf.stylesheets);
    if (pf.renderBlocking !== 1) errs.push("fast renderBlocking=" + pf.renderBlocking);
    if (pf.imagesMissingDimensions !== 0) errs.push("fast imagesMissingDimensions=" + pf.imagesMissingDimensions);
    if (pf.lazyImages < 3) errs.push("fast lazyImages=" + pf.lazyImages);
    if (pf.resourceHints !== true) errs.push("fast resourceHints false (preconnect/preload missed)");
    if (!(pf.inlineCssBytes > 0)) errs.push("fast inlineCssBytes not >0");
    if (pf.inlineJsBytes !== 0) errs.push("fast inlineJsBytes=" + pf.inlineJsBytes + " (external scripts miscounted as inline)");

    // --- PARSING: the SLOW page is heavy.
    if (ps.renderBlockingScripts !== 6) errs.push("slow renderBlockingScripts=" + ps.renderBlockingScripts);
    if (ps.stylesheets !== 4) errs.push("slow stylesheets=" + ps.stylesheets);
    if (ps.renderBlocking !== 10) errs.push("slow renderBlocking=" + ps.renderBlocking);
    if (ps.imagesMissingDimensions !== 4) errs.push("slow imagesMissingDimensions=" + ps.imagesMissingDimensions);
    if (ps.lazyImages !== 0) errs.push("slow lazyImages=" + ps.lazyImages);
    if (!(ps.inlineJsBytes > 0)) errs.push("slow inlineJsBytes not >0");
    if (ps.resourceHints !== false) errs.push("slow resourceHints true (no hints expected)");

    // --- SCORING: good metrics so ONLY the new signals move the score.
    const mk = (checks) => { const a = { ok: true, status: 200, metrics: { responseMs: 120, htmlBytes: 9000 }, checks }; a.scores = scoreAudit(a); return a; };
    const aFast = mk(fast); const aSlow = mk(slow);
    if (aFast.scores.performance !== 100) errs.push("fast performance != 100 (got " + aFast.scores.performance + ")");
    if (!(aSlow.scores.performance < 100)) errs.push("slow performance not < 100 (got " + aSlow.scores.performance + ")");
    if (!(aSlow.scores.performance < aFast.scores.performance)) errs.push("slow not worse than fast");

    // --- RULES: FAST yields no new perf findings; SLOW yields the actionable ones.
    const fastIds = analyze(aFast).map((x) => x.id);
    for (const id of ["render-blocking-resources", "images-not-lazy", "images-missing-dimensions", "inline-assets-large", "resource-hints-missing"])
      if (fastIds.includes(id)) errs.push("fast unexpectedly has " + id);
    const slowFindings = analyze(aSlow);
    const slowIds = slowFindings.map((x) => x.id);
    for (const id of ["render-blocking-resources", "images-not-lazy", "images-missing-dimensions", "resource-hints-missing"])
      if (!slowIds.includes(id)) errs.push("slow missing " + id);
    const rbF = slowFindings.find((x) => x.id === "render-blocking-resources");
    if (!rbF || rbF.priority !== "high") errs.push("render-blocking not high (10 > poor)"); // 10 > poor(8)
    if (slowFindings.some((x) => x.id === "render-blocking-resources" && x.category !== "performance")) errs.push("render-blocking not category performance");
    // still sorted critical-first (non-decreasing priority weight).
    const W = { critical: 0, high: 1, medium: 2, low: 3 };
    for (let i = 1; i < slowFindings.length; i++) if (W[slowFindings[i].priority] < W[slowFindings[i - 1].priority]) errs.push("slow findings not sorted at " + i);

    // --- HUGE INLINE WEIGHT: the explicit scoring deduction + rule (threshold edge).
    const heavy = mk({ imagesTotal: 0, performance: { renderBlocking: 0, renderBlockingScripts: 0, stylesheets: 0, inlineBytes: 80000, inlineCssBytes: 80000, inlineJsBytes: 0, lazyImages: 0, imagesMissingDimensions: 0, resourceHints: true } });
    if (!(heavy.scores.performance < 100)) errs.push("huge inline did not lower performance (got " + heavy.scores.performance + ")");
    if (!analyze(heavy).map((x) => x.id).includes("inline-assets-large")) errs.push("huge inline missing inline-assets-large");

    // --- A header-less / lighthouse-style audit (no checks.performance) is untouched.
    const noPerf = analyze({ ok: true, status: 200, metrics: {}, checks: { https: true, imagesTotal: 9 }, scores: { performance: 90 } });
    for (const id of ["render-blocking-resources", "images-not-lazy", "images-missing-dimensions"])
      if (noPerf.map((x) => x.id).includes(id)) errs.push("no-perf audit wrongly got " + id);

    console.log(errs.length ? "FAIL: " + errs.join("; ") : "PERF_OK (fast perf " + aFast.scores.performance + ", slow perf " + aSlow.scores.performance + ", slow findings " + slowIds.length + ")");
  ' "${ENGINE}/probe.js" "${ENGINE}/scoring.js" "${ENGINE}/rules.js" "${FIX}/page-fast.html" "${FIX}/page-slow.html")"
  if [[ "${OUT}" == *PERF_OK* ]]; then _pass "performance: render-blocking/inline/lazy/dimensions parsed; folded into score + rules (sorted) — ${OUT#*PERF_OK }"
  else _fail "performance logic wrong — ${OUT}"; fi
else
  _skip "performance logic (node not available)"
fi

# ===========================================================================
section "AI-GATING — rule-based by default; RICH bilingual enrichment ONLY with a key (mocked seam)"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [aiP, rulesP, badP] = process.argv.slice(1);
    const { selectAiProvider, isAiEnabled, enrich } = await import(pathToFileURL(aiP).href);
    const { analyze } = await import(pathToFileURL(rulesP).href);
    const audit = JSON.parse(readFileSync(badP,"utf8"));
    const findings = analyze(audit);
    const EFFORTS = new Set(["quick-win","medium","large"]);
    const norm = (s)=>String(s||"").toLowerCase().replace(/[^a-z0-9]+/g," ").trim();
    const errs = [];

    // --- Pure gate decision (unchanged contract) ----------------------------
    if (selectAiProvider({}).enabled !== false) errs.push("empty env enabled");
    if (selectAiProvider({AI_PROVIDER:"openai"}).enabled !== false) errs.push("no-key enabled");
    if (selectAiProvider({AI_PROVIDER:"none", AI_API_KEY:"x"}).enabled !== false) errs.push("provider none enabled");
    if (selectAiProvider({AI_PROVIDER:"openai", AI_API_KEY:"sk-x"}).enabled !== true) errs.push("key not enabled");
    if (isAiEnabled({}) !== false) errs.push("isAiEnabled empty");

    // --- OFF (no env): NO fetch, findings intact, AI-only fields empty -------
    let calledOff = 0;
    const mockOff = async () => { calledOff++; return { json: async()=>({}) }; };
    const off = await enrich(findings, audit, {}, { fetchImpl: mockOff });
    if (off.ai.enabled !== false) errs.push("off ai.enabled true");
    if (calledOff !== 0) errs.push("off called fetch "+calledOff+" times (must be 0 — NO real call)");
    if (off.findings.length !== findings.length) errs.push("off mutated findings");
    if (off.ai.actionPlan.length !== 0) errs.push("off has an action plan");
    if (off.ai.executiveSummary !== null) errs.push("off has an executive summary");

    // --- provider named but NO key: still NO fetch (never half-enable) -------
    let calledNoKey = 0;
    const mockNoKey = async () => { calledNoKey++; return { json: async()=>({}) }; };
    const noKey = await enrich(findings, audit, {AI_PROVIDER:"openai"}, { fetchImpl: mockNoKey });
    if (noKey.ai.enabled !== false) errs.push("no-key ai.enabled true");
    if (calledNoKey !== 0) errs.push("no-key called fetch (must stay inert)");

    // --- ON (key set): mock returns STRICT JSON -> rich, bilingual shape -----
    const aiPayload = { executiveSummary: { ar: "AR_OK", en: "EN_OK" }, recommendations: [
      { title: "Add FAQ schema for services", recommendation: "Add FAQPage JSON-LD.", priority: "medium", category: "seo", effort: "quick-win", impact: "rich results" },
      { title: "Add a meta description", recommendation: "duplicate of a rule finding", priority: "high", category: "seo", effort: "quick-win" }
    ]};
    let calledOn = 0;
    const mockOn = async () => { calledOn++; return { json: async()=>({ choices:[{message:{content: JSON.stringify(aiPayload)}}] }) }; };
    const on = await enrich(findings, audit, {AI_PROVIDER:"openai", AI_API_KEY:"sk-x"}, { fetchImpl: mockOn });
    if (on.ai.enabled !== true) errs.push("on ai.enabled false");
    if (calledOn !== 1) errs.push("on called fetch "+calledOn+" (want 1)");
    if (on.findings.length !== findings.length) errs.push("on changed deterministic findings count");
    if (findings.some((f)=>"effort" in f)) errs.push("on MUTATED deterministic findings (added effort)");
    // bilingual executive summary present + AI ar/en passed through verbatim.
    const es = on.ai.executiveSummary;
    if (!es || typeof es.ar !== "string" || typeof es.en !== "string") errs.push("on no bilingual executiveSummary {ar,en}");
    else { if (!es.ar.length || !es.en.length) errs.push("on empty ar/en"); if (es.ar === es.en) errs.push("on ar===en (not bilingual)"); if (es.ar !== "AR_OK" || es.en !== "EN_OK") errs.push("on did not pass AI ar/en through"); }
    // action plan: merged, every item effort-tagged, all rule findings present.
    const plan = on.ai.actionPlan;
    if (!Array.isArray(plan) || plan.length < findings.length) errs.push("on actionPlan missing rule items");
    if (plan.some((p)=>!EFFORTS.has(p.effort) || !p.title)) errs.push("on action item without a valid effort/title");
    for (const f of findings) if (!plan.some((p)=>p.id===f.id && p.source==="rule")) errs.push("on plan dropped rule finding "+f.id);
    // AI insight merged in.
    if (!plan.some((p)=>p.source==="ai")) errs.push("on plan has no AI items");
    if (!plan.some((p)=>p.source==="ai" && p.title==="Add FAQ schema for services")) errs.push("on plan missing the new AI rec");
    // dedup: AI item that restates a rule finding does NOT create a duplicate.
    const md = plan.filter((p)=>norm(p.title)===norm("Add a meta description"));
    if (md.length !== 1 || md[0].source !== "rule") errs.push("on did NOT dedup AI rec against rule finding ("+md.length+")");

    // --- ON, non-JSON reply (anthropic): deterministic bilingual FALLBACK ----
    let calledA = 0; let lastUrl = ""; let lastInit = null;
    const mockA = async (url, init) => { calledA++; lastUrl = url; lastInit = init; return { json: async()=>({ content:[{text:"Just prose, not JSON."}] }) }; };
    const on2 = await enrich(findings, audit, {AI_PROVIDER:"anthropic", AI_API_KEY:"sk-y"}, { fetchImpl: mockA });
    if (calledA !== 1) errs.push("anthropic called fetch "+calledA+" (want 1)");
    if (on2.ai.provider !== "anthropic") errs.push("anthropic provider name wrong: "+on2.ai.provider);
    if (!on2.ai.executiveSummary || !on2.ai.executiveSummary.ar.length || !on2.ai.executiveSummary.en.length) errs.push("anthropic no fallback bilingual summary");
    if (on2.ai.actionPlan.length < findings.length || !on2.ai.actionPlan.every((p)=>p.source==="rule")) errs.push("anthropic fallback plan wrong (should be rule-only)");
    // anthropic request shaping: /v1/messages + x-api-key + a system prompt.
    if (!lastUrl.includes("/v1/messages")) errs.push("anthropic url wrong: "+lastUrl);
    if (!lastInit || !lastInit.headers || lastInit.headers["x-api-key"] !== "sk-y") errs.push("anthropic missing x-api-key header");
    try { const b = JSON.parse(lastInit.body); if (typeof b.system !== "string" || !b.messages) errs.push("anthropic body shape wrong"); } catch { errs.push("anthropic body not JSON"); }

    // --- ON, fetch THROWS: best-effort -> report unaffected, fallback present-
    let calledT = 0;
    const mockThrow = async () => { calledT++; throw new Error("boom"); };
    const on3 = await enrich(findings, audit, {AI_PROVIDER:"openai", AI_API_KEY:"sk-z"}, { fetchImpl: mockThrow });
    if (calledT !== 1) errs.push("throw path called fetch "+calledT);
    if (on3.ai.enabled !== true) errs.push("throw path ai.enabled false");
    if (!on3.ai.error || !String(on3.ai.error).includes("boom")) errs.push("throw path lost the error");
    if (!on3.ai.executiveSummary || !on3.ai.executiveSummary.ar.length) errs.push("throw path no fallback summary");
    if (on3.ai.actionPlan.length < findings.length) errs.push("throw path lost the rule-based plan");
    if (on3.findings.length !== findings.length) errs.push("throw path changed deterministic findings");

    // --- ON, timeout: an AbortSignal is WIRED + an AbortError degrades cleanly --
    let sawSignal = false; let calledTo = 0;
    const mockTimeout = async (url, init) => { calledTo++; sawSignal = !!(init && init.signal); const e = new Error("aborted"); e.name = "AbortError"; throw e; };
    const on4 = await enrich(findings, audit, {AI_PROVIDER:"openai", AI_API_KEY:"sk-t", AI_TIMEOUT_MS:"1234"}, { fetchImpl: mockTimeout });
    if (calledTo !== 1) errs.push("timeout path called fetch "+calledTo);
    if (!sawSignal) errs.push("timeout path: no AbortSignal passed to fetch (timeout not wired)");
    if (on4.ai.enabled !== true) errs.push("timeout path ai.enabled false");
    if (!on4.ai.error || !/timed out/i.test(String(on4.ai.error))) errs.push("timeout path lost the timeout error: "+on4.ai.error);
    if (!on4.ai.executiveSummary || !on4.ai.executiveSummary.ar.length) errs.push("timeout path no fallback summary");
    if (on4.ai.actionPlan.length < findings.length) errs.push("timeout path lost the rule-based plan");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "AI_OK");
  ' "${ENGINE}/ai.js" "${ENGINE}/rules.js" "${FIX}/audit-bad.json")"
  if [[ "${OUT}" == *AI_OK* ]]; then _pass "ai: inert without a key (no fetch); rich bilingual+effort enrichment only with a key (mocked, no real call)"
  else _fail "ai enrichment wrong — ${OUT}"; fi

  # NOTIFY: the optional Uptime-Kuma push is TIME-BOUNDED (an AbortSignal is passed so a
  # hung Kuma endpoint can't block the audit) and stays best-effort (a throwing fetch is
  # swallowed; the local summary file is always written regardless).
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { mkdtempSync } from "node:fs";
    import { tmpdir } from "node:os";
    import { join } from "node:path";
    const [notifyP] = process.argv.slice(1);
    const { notify } = await import(pathToFileURL(notifyP).href);
    const errs = [];
    const root = mkdtempSync(join(tmpdir(), "seo-notify-"));
    // (1) Kuma configured -> a time-bounded push carrying status+msg.
    let kumaUrl = null; let sawSignal = false;
    const fetchImpl = async (u, init) => { kumaUrl = String(u); sawSignal = !!(init && init.signal); return { ok: true }; };
    const r = await notify(root, "audit done", { critical: 0, high: 1 }, { SEO_UPTIME_KUMA_PUSH_URL: "https://kuma.example/api/push/x" }, { fetchImpl });
    if (r.kuma !== true) errs.push("kuma not marked sent");
    if (!kumaUrl || !kumaUrl.includes("msg=")) errs.push("kuma msg missing");
    if (!sawSignal) errs.push("kuma push not time-bounded (no AbortSignal)");
    // (2) A throwing fetch is swallowed (best-effort) and the local file is still written.
    let threw = 0;
    try { const r2 = await notify(root, "x", { critical: 1 }, { SEO_UPTIME_KUMA_PUSH_URL: "https://kuma.example/api/push/y" }, { fetchImpl: async () => { throw new Error("down"); } });
      if (!r2.wrote) errs.push("local summary not written when kuma throws"); }
    catch { threw = 1; }
    if (threw) errs.push("a throwing kuma push was not swallowed");
    console.log(errs.length ? "FAIL: "+errs.join("; ") : "NOTIFY_OK");
  ' "${ENGINE}/notify.js")"
  if [[ "${OUT}" == *NOTIFY_OK* ]]; then _pass "notify: Kuma push is time-bounded (AbortSignal) + best-effort; local summary always written"
  else _fail "notify timeout/best-effort wrong — ${OUT}"; fi
else
  _skip "ai gating (node not available)"
fi

# ===========================================================================
section "DEPTH — pure cost-vs-depth selector: validation + precedence + key-presence default (engine/depth.js)"
# ---------------------------------------------------------------------------
# Pure, offline, deterministic. Three levels (quick / standard / deep), one
# explicit dial per run. Validation rejects unknown values (the rejection is
# what stops a typo from spending a container). Precedence: explicit --depth
# wins; legacy --panel = deep (back-compat); else SEO_DEFAULT_DEPTH; else the
# key-presence default ('standard' when AI_PROVIDER+AI_API_KEY are set, else
# 'quick'). capabilitiesFor maps each level to the seams the audit should run.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [depthP] = process.argv.slice(1);
    const { DEPTHS, isValidDepth, assertDepth, resolveDepth, capabilitiesFor, depthLabel } = await import(pathToFileURL(depthP).href);
    const errs = [];

    // --- The exact, documented set of levels (the public contract) ---------
    if (JSON.stringify(DEPTHS) !== JSON.stringify(["quick","standard","deep"])) errs.push("DEPTHS wrong: "+JSON.stringify(DEPTHS));
    for (const v of DEPTHS) if (!isValidDepth(v)) errs.push("isValidDepth false for "+v);

    // --- Unknown values are rejected with a clear, listing message ---------
    for (const bad of ["", "QUICK", "fast", "panel", "true", "0", "null", null, undefined]) {
      try { assertDepth(bad); errs.push("assertDepth accepted "+JSON.stringify(bad)); }
      catch (e) {
        if (!/unknown analysis depth/i.test(String(e.message))) errs.push("assertDepth msg lacks marker: "+e.message);
        if (!/quick \| standard \| deep/.test(String(e.message))) errs.push("assertDepth msg lacks valid list: "+e.message);
      }
    }

    // --- Explicit --depth wins (and is validated) --------------------------
    if (resolveDepth({ depth: "quick" },    { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }) !== "quick")    errs.push("explicit quick lost");
    if (resolveDepth({ depth: "standard" }, {}) !== "standard") errs.push("explicit standard lost");
    if (resolveDepth({ depth: "deep" },     {}) !== "deep")     errs.push("explicit deep lost");
    try { resolveDepth({ depth: "fast" }, {}); errs.push("resolveDepth accepted bad value"); }
    catch (e) { if (!/unknown analysis depth/.test(String(e.message))) errs.push("resolveDepth bad msg: "+e.message); }
    // A bare flag (true) is NOT a value — falls through to lower-priority sources.
    if (resolveDepth({ depth: true }, {}) !== "quick") errs.push("bare --depth true did not fall through");

    // --- Legacy --panel maps to depth=deep (back-compat) -------------------
    if (resolveDepth({ panel: true },  {}) !== "deep") errs.push("--panel did not map to deep");
    if (resolveDepth({ panel: "1" },   {}) !== "deep") errs.push("--panel \"1\" not deep");
    // explicit --depth still WINS over --panel.
    if (resolveDepth({ depth: "quick", panel: true }, {}) !== "quick") errs.push("--depth did not beat --panel");

    // --- SEO_DEFAULT_DEPTH env override (validated) ------------------------
    if (resolveDepth({}, { SEO_DEFAULT_DEPTH: "standard" }) !== "standard") errs.push("env default standard lost");
    if (resolveDepth({}, { SEO_DEFAULT_DEPTH: "deep", AI_PROVIDER:"none" }) !== "deep") errs.push("env default deep lost");
    try { resolveDepth({}, { SEO_DEFAULT_DEPTH: "fast" }); errs.push("env accepted bad value"); }
    catch (e) { if (!/unknown analysis depth/.test(String(e.message))) errs.push("env bad msg: "+e.message); }
    // --depth still wins over the env.
    if (resolveDepth({ depth: "quick" }, { SEO_DEFAULT_DEPTH: "deep" }) !== "quick") errs.push("--depth did not beat env");

    // --- Key-presence default ----------------------------------------------
    if (resolveDepth({}, {}) !== "quick") errs.push("no-key default not quick");
    if (resolveDepth({}, { AI_PROVIDER:"openai" }) !== "quick") errs.push("provider-without-key did not stay quick");
    if (resolveDepth({}, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }) !== "standard") errs.push("key-set default not standard");

    // --- capabilitiesFor: each level maps to the right seams --------------
    const q = capabilitiesFor("quick");    if (q.ai !== false || q.panel !== false) errs.push("quick caps wrong: "+JSON.stringify(q));
    const s = capabilitiesFor("standard"); if (s.ai !== true  || s.panel !== false) errs.push("standard caps wrong: "+JSON.stringify(s));
    const d = capabilitiesFor("deep");     if (d.ai !== true  || d.panel !== true)  errs.push("deep caps wrong: "+JSON.stringify(d));
    try { capabilitiesFor("fast"); errs.push("capabilitiesFor accepted bad"); } catch {}

    // --- depthLabel is bilingual + identifies the level --------------------
    if (!/rules-only/i.test(depthLabel("quick", "en")))     errs.push("quick en label wrong");
    if (!/قواعد/i.test(depthLabel("quick", "ar")))           errs.push("quick ar label wrong");
    if (!/specialist panel/i.test(depthLabel("deep", "en"))) errs.push("deep en label wrong");
    if (!/فريق/i.test(depthLabel("deep", "ar")))             errs.push("deep ar label wrong");
    // unknown locale -> ar (RTL-first default); unknown depth -> standard fallback.
    if (depthLabel("deep") !== depthLabel("deep", "ar")) errs.push("no-locale did not default to ar");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "DEPTH_PURE_OK");
  ' "${ENGINE}/depth.js")"
  if [[ "${OUT}" == *DEPTH_PURE_OK* ]]; then _pass "depth: 3 levels, unknown rejected; --depth > --panel > env > key-presence; capabilities map per level; bilingual label"
  else _fail "depth pure logic wrong — ${OUT}"; fi

  # The DEPTH module is a PURE selector: NO network/transport/scraper token.
  fhasnt "depth.js makes NO direct fetch call" "${ENGINE}/depth.js" "fetch("
  tests_run=$((tests_run+1))
  if grep -nE "nodemailer|createTransport|sendgrid|mailgun|twilio|puppeteer|playwright|cheerio|serpapi|googleapis|nominatim|smtplib|XMLHttpRequest" "${ENGINE}/depth.js" >/dev/null 2>&1; then
    _fail "depth.js contains a transport/scraper token"
  else _pass "depth.js has NO transport/scraper token"; fi

  # WIRING: each level invokes the RIGHT seams via mocked fetch — quick=0 fetches,
  # standard=1, deep=panel (many) — and renderReport surfaces the chosen depth in
  # the report header. Drives the SAME modules (enrich + runSpecialistPanel) the
  # CLI threads through via capabilitiesFor — proves the depth-to-seam mapping
  # without spawning a container or hitting the network.
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [depthP, aiP, spP, rulesP, reportP, badP] = process.argv.slice(1);
    const { capabilitiesFor } = await import(pathToFileURL(depthP).href);
    const { enrich } = await import(pathToFileURL(aiP).href);
    const { runSpecialistPanel, renderPanelSection } = await import(pathToFileURL(spP).href);
    const { analyze } = await import(pathToFileURL(rulesP).href);
    const { renderReport } = await import(pathToFileURL(reportP).href);
    const audit = JSON.parse(readFileSync(badP, "utf8"));
    const findings = analyze(audit);
    const errs = [];

    // The mock reply satisfies BOTH the enrichment JSON shape AND the specialist
    // JSON shape (so a single reply can drive every call in the panel run).
    const reply = JSON.stringify({
      executiveSummary:{ar:"AR_SUM", en:"EN_SUM"},
      recommendations:[],
      severity:"high",
      deepAnalysis:{ar:"عربي", en:"english"},
      businessImpact:{ar:"أثر", en:"impact"},
      prioritizedFixes:[{ fix:{ar:"إصلاح", en:"fix"}, effort:"medium", impact:{ar:"أ", en:"i"} }],
      claims:[]
    });
    const env = { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" };

    // The pipeline path the CLI runs, parameterised by depth — matches audit.js
    // exactly (enrich gated on caps.ai, panel gated on caps.panel).
    const runLevel = async (depth) => {
      const caps = capabilitiesFor(depth);
      let calls = 0;
      const stubFetch = async () => { calls++; return { json: async()=>({ choices:[{message:{content: reply}}] }) }; };
      const enriched = caps.ai
        ? await enrich(findings, audit, env, { fetchImpl: stubFetch })
        : { ai: { enabled: false, executiveSummary: null, actionPlan: [] } };
      const stubFetchSp = async () => { calls++; return { json: async()=>({ choices:[{message:{content: reply}}] }) }; };
      const a = { ...audit, depth };
      let report = renderReport(a, findings, { ai: enriched.ai });
      if (caps.panel) {
        const bundle = await runSpecialistPanel(a, env, { aiFetchImpl: stubFetchSp });
        report = report + "\n" + renderPanelSection(bundle, { locale: "en" });
      }
      return { calls, report };
    };

    // quick -> 0 fetches; rules-only; header reflects the level.
    const q = await runLevel("quick");
    if (q.calls !== 0) errs.push("quick made "+q.calls+" fetches (must be 0)");
    if (!/\*\*Depth:\*\* quick — rules-only/.test(q.report)) errs.push("quick header missing depth marker");
    if (/## Specialist panel/.test(q.report)) errs.push("quick wrongly added the panel section");
    if (/## AI enrichment/.test(q.report)) errs.push("quick wrongly added the AI enrichment block");

    // standard -> exactly 1 fetch (the single enrichment call); header reflects the level.
    const s = await runLevel("standard");
    if (s.calls !== 1) errs.push("standard made "+s.calls+" fetches (want 1)");
    if (!/\*\*Depth:\*\* standard/.test(s.report)) errs.push("standard header missing depth marker");
    if (/## Specialist panel/.test(s.report)) errs.push("standard wrongly added the panel section");
    if (!/## AI enrichment/.test(s.report)) errs.push("standard missing the AI enrichment block");

    // deep -> enrichment + panel; header reflects the level; panel section appended.
    const d = await runLevel("deep");
    if (!(d.calls >= 2)) errs.push("deep made "+d.calls+" fetches (want >= 2 — enrich + panel)");
    if (!/\*\*Depth:\*\* deep/.test(d.report)) errs.push("deep header missing depth marker");
    if (!/## Specialist panel/.test(d.report)) errs.push("deep missing the panel section");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "DEPTH_WIRE_OK (quick="+q.calls+" standard="+s.calls+" deep="+d.calls+")");
  ' "${ENGINE}/depth.js" "${ENGINE}/ai.js" "${ENGINE}/specialists.js" "${ENGINE}/rules.js" "${ENGINE}/report.js" "${FIX}/audit-bad.json")"
  if [[ "${OUT}" == *DEPTH_WIRE_OK* ]]; then _pass "depth wiring: quick=0 fetches/no AI block; standard=1 fetch/no panel; deep=enrich+panel section; report header reflects the level — ${OUT#*DEPTH_WIRE_OK }"
  else _fail "depth wiring wrong — ${OUT}"; fi
else
  _skip "depth (node not available)"
fi

# Wiring: seo.sh exposes the flag + validates; engine threads it through; .env documents it.
fhas  "audit.js imports depth resolver"          "${ENGINE}/audit.js" "from './depth.js'"
fhas  "audit.js audit subcommand uses resolveDepth" "${ENGINE}/audit.js" "resolveDepth({ depth: args.depth"
fhas  "report.js imports the depth label"        "${ENGINE}/report.js" "from './depth.js'"
fhas  "seo-lib defines SEO_DEPTHS"               "${LIB}" "SEO_DEPTHS="
fhas  "seo-lib has seo_valid_depth"              "${LIB}" "seo_valid_depth()"
fhas  "seo.sh accepts --depth"                   "${HELPER}" "--depth)"
fhas  "seo.sh validates --depth before docker"   "${HELPER}" "seo_valid_depth"
fhas  "seo.sh forwards --depth to the auditor"   "${HELPER}" 'extra+=(--depth "${DEPTH}")'
fhas  ".env.example has SEO_DEFAULT_DEPTH="      "${ENVX}" "SEO_DEFAULT_DEPTH="
fhas  ".env.example pins the per-level cost"     "${ENVX}" "0 AI calls"
fhas  ".env.example documents 7 AI calls (deep)" "${ENVX}" "7 AI calls"
fhas  "README documents analysis depth"          "${PROJECT_ROOT}/services/seo/README.md" "Analysis depth"
ok    "seo.sh rejects an unknown --depth"        bash -c '! "'"${HELPER}"'" audit foo --depth=fast >/dev/null 2>&1'
ok    "seo-lib: valid depths"                    bash -c '. "'"${LIB}"'"; seo_valid_depth quick && seo_valid_depth standard && seo_valid_depth deep'
no    "seo-lib: rejects an unknown depth"        bash -c '. "'"${LIB}"'"; seo_valid_depth fast'

# ===========================================================================
section "COMPETITORS — pure compareSites + SSRF-guarded probeCompetitors (engine/competitors.js)"
# ---------------------------------------------------------------------------
# Pure orchestration on top of the EXISTING probe. compareSites is deterministic
# and uses only REAL audit fields — never invents a figure (mirrors guardNumbers
# discipline structurally: there is no AI seam to defend against). probeCompetitors
# reuses the SAME SSRF-guarded probeUrl: a private/redirecting competitor URL is
# refused (recorded with the non-leaky reason) and NEVER fatal. The count is bounded
# by MAX_COMPETITORS (= 3). buildProspectReport renders the section additively. The
# module has NO transport/scraper token.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [compP, reportP, goodP, badP, downP] = process.argv.slice(1);
    const M = await import(pathToFileURL(compP).href);
    const { compareSites, probeCompetitors, renderCompetitorSection, MAX_COMPETITORS } = M;
    const { buildProspectReport } = await import(pathToFileURL(reportP).href);
    const good = JSON.parse(readFileSync(goodP, "utf8"));   // strong site (100s)
    const bad  = JSON.parse(readFileSync(badP, "utf8"));    // weak site (low scores, slow)
    const down = JSON.parse(readFileSync(downP, "utf8"));   // unreachable
    const errs = [];

    if (MAX_COMPETITORS !== 3) errs.push("MAX_COMPETITORS != 3 (got "+MAX_COMPETITORS+")");

    // (1) PURE compareSites: primary trails the competitor in EVERY category → big gaps;
    //     all numbers in the output trace back to the input audits (no invention).
    const c1 = compareSites(bad, [good]);
    if (!c1 || typeof c1 !== "object") errs.push("compareSites returned non-object");
    if (!c1.primary || c1.primary.url !== bad.url) errs.push("primary not echoed");
    if (!Array.isArray(c1.competitors) || c1.competitors.length !== 1) errs.push("competitors len wrong");
    const cmp = c1.competitors[0];
    if (cmp.url !== good.url) errs.push("competitor url not echoed");
    if (cmp.ok !== true) errs.push("good competitor should be ok");
    if (!cmp.deltas || cmp.deltas.performance == null) errs.push("deltas missing");
    // Every delta is competitor - primary; with bad as primary and good as competitor,
    // all deltas should be POSITIVE (competitor ahead).
    for (const k of Object.keys(cmp.deltas)) if (cmp.deltas[k] !== null && cmp.deltas[k] <= 0) errs.push("delta "+k+" not positive: "+cmp.deltas[k]);
    if (!Array.isArray(c1.gaps) || c1.gaps.length === 0) errs.push("no gaps surfaced");
    // Performance gap surfaces the response-time PAIR (real audit metrics).
    const perfGap = c1.gaps.find((g) => g.category === "performance");
    if (!perfGap) errs.push("no perf gap");
    else {
      if (!perfGap.metric || perfGap.metric.key !== "responseMs") errs.push("perf gap missing responseMs metric");
      if (perfGap.metric.primary !== bad.metrics.responseMs) errs.push("perf gap primary ms wrong: "+perfGap.metric.primary+" vs real "+bad.metrics.responseMs);
      if (perfGap.metric.best !== good.metrics.responseMs) errs.push("perf gap best ms wrong: "+perfGap.metric.best+" vs real "+good.metrics.responseMs);
    }
    // NO INVENTED NUMBERS: every numeric in the structured output is in the input
    // audits (or 0/100 sentinels) — verify by walking the structure.
    const inputs = new Set([0, 100]);
    const walk = (v) => { if (v == null) return;
      if (typeof v === "number" && Number.isFinite(v)) { inputs.add(v); return; }
      if (Array.isArray(v)) { v.forEach(walk); return; }
      if (typeof v === "object") for (const k of Object.keys(v)) walk(v[k]); };
    walk(bad); walk(good);
    // Allow simple arithmetic over inputs (deltas) — but every value cited as primary/best/responseMs IS in inputs.
    const allowed = (n) => inputs.has(n);
    if (!allowed(perfGap.primary)) errs.push("perf gap primary is not from inputs: "+perfGap.primary);
    if (!allowed(perfGap.best))    errs.push("perf gap best is not from inputs: "+perfGap.best);

    // DETERMINISM: same inputs => byte-identical output.
    if (JSON.stringify(compareSites(bad, [good])) !== JSON.stringify(c1)) errs.push("compareSites not deterministic");

    // (2) A BLOCKED/FAILED competitor is RECORDED, never fatal.
    const blockedAudit = { name:"c1", url:"http://10.0.0.1/", ok:false, status:"blocked by SSRF guard: refusing private/reserved IPv4 address (10.0.0.1)", scores:{} };
    const c2 = compareSites(bad, [good, blockedAudit]);
    if (c2.competitors.length !== 2) errs.push("blocked competitor not kept in list");
    const blk = c2.competitors[1];
    if (blk.ok !== false) errs.push("blocked competitor ok != false");
    if (!blk.blockedReason || !/blocked by ssrf guard/i.test(blk.blockedReason)) errs.push("blockedReason not surfaced");
    // gaps must only consider REACHABLE competitors.
    if (c2.gaps.length !== c1.gaps.length) errs.push("gaps changed because a blocked competitor was counted");

    // (3) NO MATERIAL GAP: when primary == competitor, gaps is empty.
    const c3 = compareSites(good, [good]);
    if (c3.gaps.length !== 0) errs.push("self-vs-self produced gaps");

    // (4) probeCompetitors: bounded count (MAX_COMPETITORS); over-cap is refused.
    let threw = "";
    try { await probeCompetitors(["https://a","https://b","https://c","https://d"], {}); }
    catch (e) { threw = String(e.message || e); }
    if (!/too many competitors/i.test(threw)) errs.push("over-cap not refused: "+threw);

    // (5) probeCompetitors HONOURS the SSRF guard via probeUrl: a private/literal-internal
    //     URL is recorded as ok:false (the same path probeUrl uses). Drive it with an
    //     injected DNS resolver so no real network/DNS happens.
    const resolve = async (h) => { if (h === "ok.example") return ["93.184.216.34"]; throw new Error("NXDOMAIN"); };
    const fetchImpl = async () => ({ status: 200, headers: new Map(), text: async () => "<!doctype html><html><head><title>ok page hi there</title></head><body><h1>x</h1></body></html>" });
    const competitors = await probeCompetitors(
      ["http://127.0.0.1/", "http://10.0.0.1/x", "https://ok.example/"],
      { fetchImpl, resolve, now: () => Date.parse("2026-05-25T00:00:00Z") },
    );
    if (competitors.length !== 3) errs.push("probeCompetitors returned "+competitors.length);
    if (competitors[0].ok !== false || !/blocked by ssrf/i.test(String(competitors[0].status))) errs.push("loopback not refused: "+JSON.stringify(competitors[0].status));
    if (competitors[1].ok !== false || !/blocked by ssrf/i.test(String(competitors[1].status))) errs.push("RFC1918 not refused: "+JSON.stringify(competitors[1].status));
    if (competitors[2].ok !== true) errs.push("public competitor wrongly refused");

    // (6) RENDER: bilingual section, real numbers; additive when empty.
    if (renderCompetitorSection({ competitors: [] }, { locale:"en" }) !== "") errs.push("empty list did not render empty");
    const sec = renderCompetitorSection(c1, { locale:"en" });
    if (!/## Competitor comparison/.test(sec)) errs.push("en: no section heading");
    if (!/Key gaps/.test(sec)) errs.push("en: no key gaps line");
    if (!new RegExp("Loads in \\d+\\.\\ds vs \\d+\\.\\ds").test(sec)) errs.push("en: missing seconds-pair line");
    // The numbers in the rendered seconds-pair must derive from the REAL responseMs.
    const ps = (Math.round(bad.metrics.responseMs / 100) / 10).toFixed(1);
    const bs = (Math.round(good.metrics.responseMs / 100) / 10).toFixed(1);
    if (!sec.includes("Loads in " + ps + "s vs " + bs + "s")) errs.push("en: seconds pair not from real audit numbers");
    const secAr = renderCompetitorSection(c1, { locale:"ar" });
    if (!/## مقارنة المنافسين/.test(secAr)) errs.push("ar: no section heading");
    if (!/يُحمَّل في/.test(secAr)) errs.push("ar: missing seconds-pair");

    // A blocked competitor is called out before the table (so the operator sees what did not probe).
    const secBlocked = renderCompetitorSection(c2, { locale:"en" });
    if (!/not audited/i.test(secBlocked)) errs.push("blocked competitor not called out");
    if (!/blocked by SSRF guard/i.test(secBlocked)) errs.push("blocked reason not shown");

    // (7) WIRING: buildProspectReport renders the section when audit.competitors exists.
    const attached = { ...bad, competitors: c1 };
    const rep = buildProspectReport(attached, { locale:"en" });
    if (!/## Competitor comparison/.test(rep)) errs.push("buildProspectReport did not include the section");
    // ADDITIVE: with no competitors, the section is absent.
    if (/## Competitor comparison/.test(buildProspectReport(bad, { locale:"en" }))) errs.push("section appeared with no competitors");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "COMPETITORS_OK");
  ' "${ENGINE}/competitors.js" "${ENGINE}/report.js" "${FIX}/audit-good.json" "${FIX}/audit-bad.json" "${FIX}/audit-unreachable.json")"
  if [[ "${OUT}" == *COMPETITORS_OK* ]]; then _pass "competitors: pure compareSites (real numbers, deterministic); SSRF-guarded probe; bounded; bilingual section; additive in buildProspectReport"
  else _fail "competitors logic wrong — ${OUT}"; fi

  # The competitors module is PURE orchestration: NO direct fetch/transport tokens.
  fhasnt "competitors.js makes NO direct fetch call" "${ENGINE}/competitors.js" "fetch("
  tests_run=$((tests_run+1))
  if grep -nE "nodemailer|createTransport|sendgrid|mailgun|twilio|puppeteer|playwright|cheerio|serpapi|googleapis|nominatim|smtplib|XMLHttpRequest" "${ENGINE}/competitors.js" >/dev/null 2>&1; then
    _fail "competitors.js contains a transport/scraper token"
  else _pass "competitors.js has NO transport/scraper token"; fi
else
  _skip "competitors (node not available)"
fi
# Wiring: --competitor flag accepted + validated; audit.js threads it through.
fhas  "audit.js imports the competitors engine"       "${ENGINE}/audit.js" "from './competitors.js'"
fhas  "audit.js gates competitors on the bound"       "${ENGINE}/audit.js" "MAX_COMPETITORS"
fhas  "audit.js calls probeCompetitors"               "${ENGINE}/audit.js" "probeCompetitors("
fhas  "report.js imports renderCompetitorSection"     "${ENGINE}/report.js" "renderCompetitorSection"
fhas  "seo-lib defines SEO_MAX_COMPETITORS=3"         "${LIB}" "SEO_MAX_COMPETITORS=3"
fhas  "seo-lib has seo_valid_url"                     "${LIB}" "seo_valid_url()"
fhas  "seo.sh accepts --competitor (repeatable)"      "${HELPER}" "--competitor)"
fhas  "seo.sh forwards --competitor to the auditor"   "${HELPER}" 'extra+=(--competitor "${_u}")'
fhas  "seo.sh bounds --competitor before docker"      "${HELPER}" "Too many --competitor"
ok    "seo.sh rejects too many --competitor"          bash -c '! "'"${HELPER}"'" audit foo --url https://x --competitor https://a --competitor https://b --competitor https://c --competitor https://d >/dev/null 2>&1'
ok    "seo.sh rejects a bad --competitor URL"         bash -c '! "'"${HELPER}"'" audit foo --url https://x --competitor not-a-url >/dev/null 2>&1'
ok    "seo-lib: valid http url"                       bash -c '. "'"${LIB}"'"; seo_valid_url https://example.com'
no    "seo-lib: rejects a non-http url"               bash -c '. "'"${LIB}"'"; seo_valid_url ftp://example.com'
no    "seo-lib: rejects a url with whitespace"        bash -c '. "'"${LIB}"'"; seo_valid_url "https://x y"'

# ===========================================================================
section "DIFF — re-audit delta engine: structured change + bilingual summary (engine/diff.js)"
# ---------------------------------------------------------------------------
# Pure, offline, deterministic: diffAudits(previous,current) compares a site's newest
# audit against its previous one and returns a structured delta — per-category score
# change + direction, overall + tier change, and a findings delta (resolved/new/
# persisting, each compacted to {id,priority,category,title}). Edge cases handled purely:
# baseline (no previous), recovery (unreachable→reachable), and outage (reachable→
# unreachable, flagged critical). summarizeDiff(delta,{locale}) renders a bilingual
# one-paragraph "what changed", critical regressions FIRST. isMeaningfulChange gates alerts.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [diffP, goodP, badP, downP] = process.argv.slice(1);
    const { diffAudits, summarizeDiff, isMeaningfulChange } = await import(pathToFileURL(diffP).href);
    const load = (p) => JSON.parse(readFileSync(p, "utf8"));
    const good = load(goodP), bad = load(badP), down = load(downP);
    const errs = [];

    // --- IMPROVED (bad -> good): up, tier up, issues resolved, NOT alert-worthy ---
    const improved = diffAudits(bad, good);
    if (improved.baseline) errs.push("improved flagged baseline");
    if (improved.overall.direction !== "up") errs.push("improved overall not up");
    if (improved.tier.direction !== "up" || improved.tierDropped) errs.push("improved tier not up");
    if (!(improved.findings.resolved.length > 0)) errs.push("improved resolved empty");
    if (improved.findings.new.length !== 0) errs.push("improved has new findings");
    if (improved.hasNewCritical || improved.hasNewHigh) errs.push("improved has new crit/high");
    if (isMeaningfulChange(improved)) errs.push("improved wrongly meaningful (no regression)");

    // --- REGRESSED (good -> bad): down, tier drop, NEW crit/high, ALERT-worthy ----
    const regressed = diffAudits(good, bad);
    if (regressed.overall.direction !== "down") errs.push("regressed overall not down");
    if (!regressed.tierDropped || regressed.tier.direction !== "down") errs.push("regressed tier not dropped");
    if (!regressed.hasNewCritical) errs.push("regressed no new critical");
    if (!regressed.hasNewHigh) errs.push("regressed no new high");
    if (regressed.findings.resolved.length !== 0) errs.push("regressed has resolved");
    if (!isMeaningfulChange(regressed)) errs.push("regressed not meaningful");

    // --- BASELINE (null -> good): first run, nothing to compare, NOT alert-worthy -
    const baseline = diffAudits(null, good);
    if (baseline.baseline !== true) errs.push("baseline not flagged");
    if (isMeaningfulChange(baseline)) errs.push("baseline wrongly meaningful");
    if (!/baseline/i.test(summarizeDiff(baseline, { locale: "en" }))) errs.push("baseline summary missing baseline word");
    if (!summarizeDiff(baseline, { locale: "ar" }).includes("خط أساس")) errs.push("baseline AR summary wrong");

    // --- RECOVERY (down -> good): recovered, NOT a regression alert ---------------
    const recovery = diffAudits(down, good);
    if (recovery.reachability !== "recovered" || !recovery.recovered) errs.push("recovery not detected");
    if (recovery.wentOffline) errs.push("recovery wrongly wentOffline");
    if (isMeaningfulChange(recovery)) errs.push("recovery wrongly alert-worthy");

    // --- OUTAGE (good -> down): went offline (CRITICAL), ALERT-worthy, leads ------
    const outage = diffAudits(good, down);
    if (outage.reachability !== "regressed" || !outage.wentOffline) errs.push("outage not flagged offline");
    if (!outage.tierDropped) errs.push("outage tier not dropped");
    if (!isMeaningfulChange(outage)) errs.push("outage not meaningful");
    const outEn = summarizeDiff(outage, { locale: "en" });
    const outAr = summarizeDiff(outage, { locale: "ar" });
    if (!/offline/i.test(outEn)) errs.push("outage EN summary missing offline");
    if (!outAr.includes("غير متاح")) errs.push("outage AR summary missing offline");
    // CRITICAL REGRESSION LEADS: the offline clause comes before any score-drop text.
    const dropIdx = outEn.indexOf("dropped");
    if (outEn.indexOf("offline") > (dropIdx === -1 ? 1e9 : dropIdx)) errs.push("outage offline did not lead");

    // --- MIXED (synthetic): one category up, one down, overall unchanged ----------
    const m1 = { ok: true, scores: { seo: 90, performance: 60, security: 80, "best-practices": 70, accessibility: 90 } };
    const m2 = { ok: true, scores: { seo: 70, performance: 85, security: 80, "best-practices": 70, accessibility: 90 } };
    const mixed = diffAudits(m1, m2);
    if (mixed.scores.performance.direction !== "up") errs.push("mixed perf not up");
    if (mixed.scores.seo.direction !== "down") errs.push("mixed seo not down");
    if (mixed.scores.security.direction !== "same") errs.push("mixed security not same");
    if (mixed.scores.performance.delta !== 25 || mixed.scores.seo.delta !== -20) errs.push("mixed deltas wrong");
    const mixEn = summarizeDiff(mixed, { locale: "en" });
    if (!/Performance improved/.test(mixEn) || !/SEO dropped/.test(mixEn)) errs.push("mixed summary wrong: " + mixEn);

    // --- FINDINGS DELTA + COMPACTION (controlled, attached findings) --------------
    const prevF = { ok: true, verdict: { overall: 80, tier: "good" }, findings: [
      { id: "a", priority: "high", category: "seo", title: "A", detail: "d", recommendation: "r" },
      { id: "b", priority: "medium", category: "performance", title: "B", detail: "d", recommendation: "r" },
    ] };
    const curF = { ok: true, verdict: { overall: 60, tier: "fair" }, findings: [
      { id: "b", priority: "medium", category: "performance", title: "B", detail: "d", recommendation: "r" },
      { id: "c", priority: "critical", category: "security", title: "C", detail: "d", recommendation: "r" },
    ] };
    const fd = diffAudits(prevF, curF);
    if (fd.findings.resolved.map(x=>x.id).join() !== "a") errs.push("resolved wrong: " + JSON.stringify(fd.findings.resolved.map(x=>x.id)));
    if (fd.findings.new.map(x=>x.id).join() !== "c") errs.push("new wrong: " + JSON.stringify(fd.findings.new.map(x=>x.id)));
    if (fd.findings.persisting.map(x=>x.id).join() !== "b") errs.push("persisting wrong: " + JSON.stringify(fd.findings.persisting.map(x=>x.id)));
    // compaction: ONLY {id,priority,category,title} — detail/recommendation stripped.
    for (const bucket of ["resolved","new","persisting"]) for (const f of fd.findings[bucket]) {
      const keys = Object.keys(f).sort().join();
      if (keys !== "category,id,priority,title") errs.push(bucket+" finding not compacted: " + keys);
    }
    if (!fd.hasNewCritical) errs.push("controlled fd missing new critical");
    if (!fd.tierDropped) errs.push("controlled fd tier not dropped");

    // --- DETERMINISM: same pair in => byte-identical delta out --------------------
    if (JSON.stringify(diffAudits(good, bad)) !== JSON.stringify(regressed)) errs.push("diffAudits not deterministic");

    console.log(errs.length ? "FAIL: " + errs.join("; ") : "DIFF_OK (improved up, regressed alert, baseline, recovery, outage offline, mixed +/-)");
  ' "${ENGINE}/diff.js" "${FIX}/audit-good.json" "${FIX}/audit-bad.json" "${FIX}/audit-unreachable.json")"
  if [[ "${OUT}" == *DIFF_OK* ]]; then _pass "diff: structured delta (scores/tier/findings) + bilingual summary; baseline/recovery/outage; meaningful-change gate — ${OUT#*DIFF_OK }"
  else _fail "diff logic wrong — ${OUT}"; fi
else
  _skip "diff logic (node not available)"
fi

# ===========================================================================
section "REPORT-DIFF — buildProspectReport renders 'Changes since last audit' (strictly additive)"
# ---------------------------------------------------------------------------
# When a diff against a previous audit is supplied (opts.diff or a pre-attached
# audit.diff), buildProspectReport adds a bilingual "Changes since last audit" section
# (summary paragraph + overall move + new/resolved/persisting counts + the new high-
# priority findings). It is STRICTLY ADDITIVE: with no diff, or on a baseline (first
# run), the section is absent and the report is exactly as before.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [reportP, diffP, goodP, badP] = process.argv.slice(1);
    const { buildProspectReport } = await import(pathToFileURL(reportP).href);
    const { diffAudits } = await import(pathToFileURL(diffP).href);
    const load = (p) => JSON.parse(readFileSync(p, "utf8"));
    const good = load(goodP), bad = load(badP);
    const errs = [];
    const has = (s, sub, l) => { if (!s.includes(sub)) errs.push(l + " missing [" + sub + "]"); };
    const hasnt = (s, sub, l) => { if (s.includes(sub)) errs.push(l + " unexpectedly has [" + sub + "]"); };

    // REGRESSION diff (good -> bad) attached via opts.diff: section renders in both locales.
    const reg = diffAudits(good, bad);
    const en = buildProspectReport(bad, { locale: "en", diff: reg });
    has(en, "## Changes since last audit", "en");
    has(en, "**New issues:**", "en");
    has(en, "**Overall:**", "en");
    has(en, "New high-priority issues", "en"); // bad has a new critical/high vs good
    const ar = buildProspectReport(bad, { locale: "ar", diff: reg });
    has(ar, "## التغييرات منذ آخر فحص", "ar");
    has(ar, "**ملاحظات جديدة:**", "ar");

    // ADDITIVE: with NO diff, the section is absent (report unchanged).
    const noDiff = buildProspectReport(bad, { locale: "en" });
    hasnt(noDiff, "Changes since last audit", "no-diff");

    // BASELINE diff (null -> good): no previous => NO section (additive).
    const baseline = diffAudits(null, good);
    const baseRep = buildProspectReport(good, { locale: "en", diff: baseline });
    hasnt(baseRep, "Changes since last audit", "baseline");

    // A PRE-ATTACHED audit.diff is honoured too (the store read path attaches it).
    const attached = buildProspectReport({ ...bad, diff: reg }, { locale: "en" });
    has(attached, "## Changes since last audit", "attached");

    console.log(errs.length ? "FAIL: " + errs.join("; ") : "REPORTDIFF_OK");
  ' "${ENGINE}/report.js" "${ENGINE}/diff.js" "${FIX}/audit-good.json" "${FIX}/audit-bad.json")"
  if [[ "${OUT}" == *REPORTDIFF_OK* ]]; then _pass "report-diff: bilingual 'Changes since last audit' section; additive (absent without a diff / on baseline)"
  else _fail "report-diff wrong — ${OUT}"; fi
else
  _skip "report-diff (node not available)"
fi

# ===========================================================================
section "SPECIALISTS — multi-specialist AI panel: grounded, bilingual, one #1 priority (engine/specialists.js)"
# ---------------------------------------------------------------------------
# Gated orchestration over the shared ai.js seam. INERT without a key (0 fetches; every
# specialist incl. sales-angle + the synthesis fall back to deterministic templates, all
# refs real). With a key + panel: each specialist calls; one garbled reply degrades
# INDEPENDENTLY; the lead synthesis yields EXACTLY ONE #1 priority; the real-number guard
# strips an invented figure; unverified claims are labeled; bilingual shape present. The
# module carries NO fetch/transport/scraper token (pure behind the provider seam).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [spP, badP] = process.argv.slice(1);
    const M = await import(pathToFileURL(spP).href);
    const { SPECIALISTS, analyzeWithSpecialists, synthesizePanel, runSpecialistPanel, verifyGrounding, guardNumbers, collectAuditNumbers, realRefs, renderPanelSection } = M;
    const bad = JSON.parse(readFileSync(badP, "utf8"));
    const errs = [];

    // The fixed set incl. the sales-angle analyst, each a pure spec.
    if (SPECIALISTS.length !== 6) errs.push("expected 6 specialists, got " + SPECIALISTS.length);
    if (!SPECIALISTS.some((s) => s.id === "sales-angle-analyst")) errs.push("no sales-angle-analyst");
    for (const s of SPECIALISTS) for (const k of ["id","category","role","systemPrompt"]) if (!s[k]) errs.push(s.id+" missing "+k);

    const refs = realRefs(bad);
    const biOk = (o, l) => o && o.deepAnalysis && o.deepAnalysis.ar && o.deepAnalysis.en && o.businessImpact && o.businessImpact.ar && o.businessImpact.en;

    // --- INERT (no key): 0 fetches, all template, all refs real, single #1 -------
    let calledOff = 0;
    const mockOff = async () => { calledOff++; return { json: async()=>({}) }; };
    const off = await runSpecialistPanel(bad, {}, { aiFetchImpl: mockOff });
    if (calledOff !== 0) errs.push("INERT made "+calledOff+" fetches (must be 0)");
    if (off.specialists.length !== SPECIALISTS.length) errs.push("INERT wrong specialist count");
    if (!off.specialists.every((s) => s.source === "template")) errs.push("INERT not all template");
    for (const s of off.specialists) {
      if (!biOk(s)) errs.push("INERT "+s.id+" not bilingual");
      for (const g of (s.grounded||[])) if (!refs.has(g.basedOn)) errs.push("INERT "+s.id+" grounded ref not real: "+g.basedOn);
      for (const pf of (s.prioritizedFixes||[])) if (!["quick-win","medium","large"].includes(pf.effort)) errs.push("INERT "+s.id+" bad effort");
    }
    if (!off.panel.topPriority || typeof off.panel.topPriority !== "object" || Array.isArray(off.panel.topPriority)) errs.push("INERT topPriority not a single object");
    if (off.panel.consistency.singleTopPriority !== true) errs.push("INERT singleTopPriority false");
    if (!refs.has(off.panel.topPriority.findingId)) errs.push("INERT #1 not a real finding");
    if (!off.panel.actionPlan.length) errs.push("INERT empty action plan");
    if (!off.panel.overallNarrative.ar || !off.panel.overallNarrative.en) errs.push("INERT narrative not bilingual");

    // --- REAL NUMBERS guard ------------------------------------------------------
    const allowed = collectAuditNumbers(bad);
    const guarded = guardNumbers("loads in 9999ms; html 9000 bytes; 3 steps; 1.5s", allowed);
    if (guarded.includes("9999")) errs.push("guard kept an invented number");
    if (!guarded.includes("9000")) errs.push("guard stripped a REAL number");
    if (!guarded.includes("3 steps")) errs.push("guard stripped a bare ordinal");
    if (guarded.includes("1.5")) errs.push("guard kept an invented decimal");

    // --- verifyGrounding split ---------------------------------------------------
    const vg = verifyGrounding({ claims:[{text:"real",basedOn:"no-https"},{text:"invented",basedOn:"fake-id-xyz"},{text:"metric",basedOn:"responseMs"}] }, bad);
    if (vg.grounded.map((g)=>g.basedOn).sort().join() !== "no-https,responseMs") errs.push("grounding grounded wrong: "+JSON.stringify(vg.grounded));
    if (vg.unverified.join() !== "invented") errs.push("grounding unverified wrong: "+JSON.stringify(vg.unverified));

    // --- WITH KEY + panel: each calls; one garbled degrades independently --------
    const good = { severity:"high", deepAnalysis:{ar:"عربي 9999ms",en:"english 9999ms big"}, businessImpact:{ar:"أثر",en:"impact"}, prioritizedFixes:[{fix:{ar:"حل",en:"fix it"},effort:"quick-win",impact:{ar:"وقع",en:"impact"}}], claims:[{text:"based real",basedOn:"no-https"},{text:"invented claim",basedOn:"made-up-nope"}] };
    let calledOn = 0;
    const mockOn = async () => { calledOn++; if (calledOn === 2) return { json: async()=>({ choices:[{message:{content:"TOTALLY NOT JSON"}}] }) }; return { json: async()=>({ choices:[{message:{content: JSON.stringify(good)}}] }) }; };
    const on = await analyzeWithSpecialists(bad, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }, { aiFetchImpl: mockOn });
    if (calledOn !== SPECIALISTS.length) errs.push("with-key made "+calledOn+" calls (want "+SPECIALISTS.length+")");
    if (on[1].source !== "template") errs.push("garbled specialist #2 did not degrade independently (source="+on[1].source+")");
    if (!on.filter((_,i)=>i!==1).every((s)=>s.source==="ai")) errs.push("other specialists not ai");
    // invented number stripped from an AI specialist; real 9000 would survive if present.
    if (on[0].deepAnalysis.en.includes("9999")) errs.push("with-key did NOT strip an invented number");
    // the off-allowlist claim is labeled unverified (general-suggestion).
    if (!(on[0].unverified || []).includes("invented claim")) errs.push("unverified claim not labeled");
    // grounded refs still real (computed by us).
    for (const g of (on[0].grounded||[])) if (!refs.has(g.basedOn)) errs.push("with-key grounded ref not real: "+g.basedOn);
    if (!biOk(on[0])) errs.push("with-key not bilingual");

    // --- Synthesis enforces ONE #1 even with multiple criticals ------------------
    const panel = synthesizePanel(on, bad);
    if (!panel.topPriority || Array.isArray(panel.topPriority)) errs.push("synthesis topPriority not single");
    if (panel.consistency.singleTopPriority !== true) errs.push("synthesis not single");
    // renderer marks unverified plainly + shows the #1.
    const sec = renderPanelSection({ specialists: on, panel }, { locale:"en" });
    if (!sec.includes("#1 priority")) errs.push("render missing #1");
    if (!/general suggestion/i.test(sec)) errs.push("render does not mark unverified as general suggestion");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "SPECIALISTS_OK (6 specialists; inert 0-fetch; one #1; number-guard; grounding)");
  ' "${ENGINE}/specialists.js" "${FIX}/audit-bad.json")"
  if [[ "${OUT}" == *SPECIALISTS_OK* ]]; then _pass "specialists: inert (0 fetch, all template, refs real, one #1); with key each calls + independent degradation; number-guard strips invented; unverified labeled; bilingual"
  else _fail "specialists wrong — ${OUT}"; fi

  fhasnt "specialists.js makes NO direct fetch call" "${ENGINE}/specialists.js" "fetch("
  tests_run=$((tests_run+1))
  if grep -nE "nodemailer|createTransport|sendgrid|mailgun|twilio|puppeteer|playwright|cheerio|serpapi|googleapis|nominatim|smtplib|XMLHttpRequest" "${ENGINE}/specialists.js" >/dev/null 2>&1; then
    _fail "specialists.js contains a transport/scraper token"
  else _pass "specialists.js has NO transport/scraper token"; fi
else
  _skip "specialists (node not available)"
fi

# ===========================================================================
section "CONTENT-IDEAS — mine OWN audit history for patterns + inbound topics (engine/content-ideas.js)"
# ---------------------------------------------------------------------------
# Pure aggregator + a gated AI step, reading ONLY local data (no scrape, no send).
# analyzeIssuePatterns(audits) is PURE: it ranks recurring findings (most-common-first)
# with simple counts (occurrences/sites/pctOfSites). generateContentIdeas turns the top
# patterns into bilingual (ar/en) educational topic ideas — inert without a key (0 fetches,
# template ideas, basedOnPattern = REAL aggregated pattern ids); with a key exactly ONE
# call; a garbled/throwing reply degrades to templates and never throws. No network without
# a key, and the module carries NO fetch/transport/scraper token.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [ciP, badP, goodP] = process.argv.slice(1);
    const { analyzeIssuePatterns, generateContentIdeas, auditsFromProspectsDb } = await import(pathToFileURL(ciP).href);
    const load = (p) => JSON.parse(readFileSync(p, "utf8"));
    const errs = [];
    const F = (id, priority, category, title) => ({ id, priority, category, title });

    // --- PURE aggregator: empty / single / many-with-repeats (controlled findings) --
    if (JSON.stringify(analyzeIssuePatterns([])) !== "[]") errs.push("empty not []");
    if (analyzeIssuePatterns(null).length !== 0) errs.push("null not []");

    const single = analyzeIssuePatterns([{ name:"a", findings:[F("no-https","critical","best-practices","No HTTPS")] }]);
    if (single.length !== 1) errs.push("single len "+single.length);
    if (single[0].occurrences !== 1 || single[0].sites !== 1 || single[0].pctOfSites !== 100) errs.push("single counts wrong: "+JSON.stringify(single[0]));
    for (const k of ["findingId","category","title","priority","occurrences","sites","pctOfSites"])
      if (!(k in single[0])) errs.push("pattern missing key "+k);

    // many-with-repeats across 3 distinct sites (a audited twice). A1 lists no-https TWICE
    // (must count ONCE per audit). totalSites=3.
    const many = analyzeIssuePatterns([
      { name:"a", findings:[F("no-https","critical","best-practices","No HTTPS"), F("no-https","critical","best-practices","No HTTPS"), F("title-missing","high","seo","Add title")] },
      { name:"a", findings:[F("no-https","critical","best-practices","No HTTPS"), F("meta-missing","high","seo","Add meta")] },
      { name:"b", findings:[F("no-https","critical","best-practices","No HTTPS"), F("title-missing","high","seo","Add title")] },
      { name:"c", findings:[] },
    ]);
    if (many.length !== 3) errs.push("many distinct "+many.length);
    if (many[0].findingId !== "no-https") errs.push("top not no-https: "+many[0].findingId);
    if (many[0].occurrences !== 3 || many[0].sites !== 2 || many[0].pctOfSites !== 67) errs.push("no-https agg wrong: "+JSON.stringify(many[0]));
    const tm = many.find((p)=>p.findingId==="title-missing");
    if (!tm || tm.occurrences !== 2 || tm.sites !== 2) errs.push("title-missing agg wrong: "+JSON.stringify(tm));
    const mm = many.find((p)=>p.findingId==="meta-missing");
    if (!mm || mm.occurrences !== 1 || mm.pctOfSites !== 33) errs.push("meta agg wrong: "+JSON.stringify(mm));
    // ranking: occurrences non-increasing.
    for (let i=1;i<many.length;i++) if (many[i].occurrences > many[i-1].occurrences) errs.push("not most-common-first at "+i);
    // deterministic.
    if (JSON.stringify(analyzeIssuePatterns([
      { name:"a", findings:[F("no-https","critical","best-practices","No HTTPS"), F("no-https","critical","best-practices","No HTTPS"), F("title-missing","high","seo","Add title")] },
      { name:"a", findings:[F("no-https","critical","best-practices","No HTTPS"), F("meta-missing","high","seo","Add meta")] },
      { name:"b", findings:[F("no-https","critical","best-practices","No HTTPS"), F("title-missing","high","seo","Add title")] },
      { name:"c", findings:[] },
    ])) !== JSON.stringify(many)) errs.push("aggregator not deterministic");

    // also derives findings via the real engine for stored audits (no .findings attached).
    const bad = load(badP);
    const real = analyzeIssuePatterns([{ ...bad, name:"x" }, { ...bad, name:"y" }, { ...load(goodP), name:"z" }]);
    const rn = real.find((p)=>p.findingId==="no-https");
    if (!rn || rn.occurrences !== 2 || rn.pctOfSites !== 67) errs.push("real-fixture agg wrong: "+JSON.stringify(rn));

    // prospects store -> audit-like objects (folds the prospects store in).
    const db = { prospects: { acme: { id:"acme", lastAnalysis:{ scores:{seo:40}, verdict:{ topFindings:[F("no-https","critical","security","No HTTPS")] } } }, none: { id:"none" } } };
    const pa = auditsFromProspectsDb(db);
    if (pa.length !== 1 || pa[0].name !== "acme" || pa[0].findings.length !== 1) errs.push("auditsFromProspectsDb wrong: "+JSON.stringify(pa));

    // --- GATED ideas: INERT (no key) -------------------------------------------
    const realIds = new Set(many.slice(0,5).map((p)=>p.findingId));
    let calledOff = 0;
    const mockOff = async () => { calledOff++; return { json: async()=>({}) }; };
    const off = await generateContentIdeas(many, {}, { aiFetchImpl: mockOff });
    if (off.enabled !== false) errs.push("off enabled true");
    if (calledOff !== 0) errs.push("off made "+calledOff+" fetches (must be 0)");
    if (off.source !== "template") errs.push("off source not template");
    if (off.dataBacked !== true) errs.push("off not dataBacked");
    if (!off.ideas.length) errs.push("off no ideas");
    const offLoc = new Set(off.ideas.map((i)=>i.locale));
    if (!offLoc.has("ar") || !offLoc.has("en")) errs.push("off not bilingual");
    for (const i of off.ideas) {
      for (const k of ["title","angle","basedOnPattern","targetAudience","locale"]) if (!i[k]) errs.push("idea missing "+k);
      if (!realIds.has(i.basedOnPattern)) errs.push("off basedOnPattern not a real pattern: "+i.basedOnPattern);
    }

    // --- GATED ideas: WITH KEY (mocked) — exactly ONE call, AI text, real basedOn --
    const payload = {}; for (const p of many.slice(0,5)) payload[p.findingId] = { ar:{title:"AR_"+p.findingId, angle:"زاوية", targetAudience:"جمهور"}, en:{title:"EN_"+p.findingId, angle:"angle", targetAudience:"audience"} };
    let calledOn = 0;
    const mockOn = async () => { calledOn++; return { json: async()=>({ choices:[{message:{content: JSON.stringify(payload)}}] }) }; };
    const on = await generateContentIdeas(many, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }, { aiFetchImpl: mockOn });
    if (on.enabled !== true) errs.push("on enabled false");
    if (calledOn !== 1) errs.push("on made "+calledOn+" calls (want 1)");
    if (on.source !== "ai") errs.push("on source not ai");
    const onLoc = new Set(on.ideas.map((i)=>i.locale));
    if (!onLoc.has("ar") || !onLoc.has("en")) errs.push("on not bilingual");
    const onAr = on.ideas.find((i)=>i.locale==="ar" && i.basedOnPattern==="no-https");
    if (!onAr || onAr.title !== "AR_no-https") errs.push("on AI text not used");
    for (const i of on.ideas) if (!realIds.has(i.basedOnPattern)) errs.push("on basedOnPattern not real: "+i.basedOnPattern);

    // --- GARBLED reply -> ONE call, degrade to template, NO throw ---------------
    let calledG = 0;
    const mockG = async () => { calledG++; return { json: async()=>({ choices:[{message:{content:"not json"}}] }) }; };
    const g = await generateContentIdeas(many, { AI_PROVIDER:"openai", AI_API_KEY:"sk-y" }, { aiFetchImpl: mockG });
    if (calledG !== 1) errs.push("garbled calls "+calledG);
    if (g.source !== "template") errs.push("garbled not degraded");
    if (!g.ideas.length) errs.push("garbled no ideas");

    // --- fetch THROWS -> best-effort template, error captured, NO throw ---------
    let calledT = 0;
    const mockT = async () => { calledT++; throw new Error("boom"); };
    const t = await generateContentIdeas(many, { AI_PROVIDER:"openai", AI_API_KEY:"sk-z" }, { aiFetchImpl: mockT });
    if (calledT !== 1) errs.push("throw calls "+calledT);
    if (t.source !== "template") errs.push("throw not template");
    if (!t.error || !String(t.error).includes("boom")) errs.push("throw lost error");

    // --- EMPTY patterns -> generic seeds (not dataBacked), still produces ideas --
    const empty = await generateContentIdeas([], {}, { aiFetchImpl: mockOff });
    if (empty.dataBacked !== false) errs.push("empty dataBacked true");
    if (!empty.ideas.length) errs.push("empty no seed ideas");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "CONTENT_IDEAS_OK (patterns ranked; ideas bilingual; inert 0-fetch; 1 call with key)");
  ' "${ENGINE}/content-ideas.js" "${FIX}/audit-bad.json" "${FIX}/audit-good.json")"
  if [[ "${OUT}" == *CONTENT_IDEAS_OK* ]]; then _pass "content-ideas: pure ranked patterns (occurrences/sites/%); bilingual ideas; inert (0 fetch, real basedOnPattern); 1 call with key; garbled/throw degrade — ${OUT#*CONTENT_IDEAS_OK }"
  else _fail "content-ideas wrong — ${OUT}"; fi

  # The module is a PURE builder behind the provider seam: NO direct network / transport.
  fhasnt "content-ideas.js makes NO direct fetch call" "${ENGINE}/content-ideas.js" "fetch("
  tests_run=$((tests_run+1))
  if grep -nE "nodemailer|createTransport|sendgrid|mailgun|twilio|puppeteer|playwright|cheerio|serpapi|googleapis|nominatim|smtplib|XMLHttpRequest" "${ENGINE}/content-ideas.js" >/dev/null 2>&1; then
    _fail "content-ideas.js contains a transport/scraper token"
  else _pass "content-ideas.js has NO transport/scraper token"; fi
else
  _skip "content-ideas (node not available)"
fi

# ===========================================================================
section "PROSPECT-REPORT — pure bilingual (ar RTL-first / en) client-facing report (engine/report.js)"
# ---------------------------------------------------------------------------
# Pure, offline, deterministic: buildProspectReport(audit,{locale}) folds ONE audit into
# a tidy Markdown report — header, overall verdict + tier, the 5 category scores table,
# top prioritised findings (critical-first) with plain recommendations, the AI executive
# summary when present, and a footer. A STRONG audit -> excellent/100 + the no-issues
# line; a WEAK audit -> poor + the critical no-https finding surfaced first; an
# UNREACHABLE audit -> 0/100 + the single unreachable finding. Verified in BOTH locales:
# 'ar' wraps the report in dir="rtl" (RTL-first), 'en' does not. Byte-identical on repeat.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [reportP, goodP, badP, downP] = process.argv.slice(1);
    const { buildProspectReport } = await import(pathToFileURL(reportP).href);
    const load = (p) => JSON.parse(readFileSync(p, "utf8"));
    const good = load(goodP), bad = load(badP), down = load(downP);
    const errs = [];
    const has = (s, sub, label) => { if (!s.includes(sub)) errs.push(label + " missing [" + sub + "]"); };
    const hasnt = (s, sub, label) => { if (s.includes(sub)) errs.push(label + " unexpectedly has [" + sub + "]"); };

    // --- Both locales render for every audit; structure is well-formed --------
    for (const [name, a] of [["good", good], ["bad", bad], ["down", down]]) {
      for (const loc of ["ar", "en"]) {
        const r = buildProspectReport(a, { locale: loc });
        const L = name + "/" + loc;
        if (typeof r !== "string" || r.length < 50) { errs.push(L + ": empty/short report"); continue; }
        // RTL-first: ar wraps in dir=rtl, en never does.
        if (loc === "ar") has(r, "dir=\"rtl\"", L); else hasnt(r, "dir=\"rtl\"", L);
        // Header + the documented section headings, localized.
        has(r, loc === "ar" ? "تقرير تحسين محركات البحث" : "SEO & site-quality report", L);
        has(r, loc === "ar" ? "## التقييم العام" : "## Overall verdict", L);
        has(r, loc === "ar" ? "## نتائج الفئات" : "## Category scores", L);
        has(r, loc === "ar" ? "## التوصيات حسب الأولوية" : "## Recommendations", L);
        // The 5-category table: a markdown table + every category label present.
        has(r, "|---|---|---|", L);
        for (const cat of (loc === "ar"
          ? ["تحسين محركات البحث", "الأداء", "الأمان", "أفضل الممارسات", "سهولة الوصول"]
          : ["SEO", "Performance", "Security", "Best practices", "Accessibility"])) has(r, cat, L);
        // Header field labels + the overall score line.
        has(r, loc === "ar" ? "**الرابط:**" : "**URL:**", L);
        has(r, a.url, L); // the actual site URL appears
        has(r, loc === "ar" ? "**النتيجة الإجمالية:**" : "**Overall score:**", L);
        // Footer (the rule + the generated-by note).
        has(r, "---", L);
        has(r, loc === "ar" ? "أُنشئ هذا التقرير تلقائيًا" : "Generated automatically", L);
      }
    }

    // --- STRONG (good) -> excellent / 100, no-issues line, NO critical marker --
    for (const loc of ["ar", "en"]) {
      const r = buildProspectReport(good, { locale: loc });
      has(r, "100/100", "good/" + loc);
      has(r, loc === "ar" ? "ممتاز" : "excellent", "good/" + loc);
      has(r, loc === "ar" ? "✅ لم تُرصد" : "✅ No issues found", "good/" + loc);
      hasnt(r, "🔴", "good/" + loc); // strong site -> no critical findings
    }

    // --- WEAK (bad) -> poor, a critical finding, no-https surfaced FIRST -------
    for (const loc of ["ar", "en"]) {
      const r = buildProspectReport(bad, { locale: loc });
      has(r, loc === "ar" ? "ضعيف" : "poor", "bad/" + loc);
      has(r, "🔴", "bad/" + loc); // has at least one critical
      has(r, "Serve the site over HTTPS", "bad/" + loc); // the no-https finding title
      has(r, loc === "ar" ? "**عدد الملاحظات:**" : "**Findings:**", "bad/" + loc);
      // no-https is the top finding -> it appears as item #1.
      const idx1 = r.indexOf("### 1.");
      if (idx1 === -1 || !r.slice(idx1, idx1 + 120).includes("Serve the site over HTTPS")) errs.push("bad/" + loc + ": no-https not item #1");
    }

    // --- UNREACHABLE (down) -> 0/100, poor, the single unreachable finding -----
    for (const loc of ["ar", "en"]) {
      const r = buildProspectReport(down, { locale: loc });
      has(r, "0/100", "down/" + loc);
      has(r, loc === "ar" ? "غير متاح" : "unreachable", "down/" + loc);
      has(r, "The site did not return a successful page", "down/" + loc);
      // exactly one finding -> there is an item #1 but no item #2.
      has(r, "### 1.", "down/" + loc);
      hasnt(r, "### 2.", "down/" + loc);
    }

    // --- AI executive summary: shown ONLY when present, in the right locale ----
    const aiBlock = { enabled: true, executiveSummary: { ar: "ملخص-عربي-تجريبي", en: "Demo-English-summary" } };
    const arEs = buildProspectReport(good, { locale: "ar", ai: aiBlock });
    const enEs = buildProspectReport(good, { locale: "en", ai: aiBlock });
    has(arEs, "## الملخص التنفيذي", "ai/ar"); has(arEs, "ملخص-عربي-تجريبي", "ai/ar");
    has(enEs, "## Executive summary", "ai/en"); has(enEs, "Demo-English-summary", "ai/en");
    // also accepted when attached to the audit object itself.
    const arAttached = buildProspectReport({ ...good, ai: aiBlock }, { locale: "ar" });
    has(arAttached, "ملخص-عربي-تجريبي", "ai/attached");
    // OFF (default): NO executive summary section.
    const noEs = buildProspectReport(good, { locale: "en" });
    hasnt(noEs, "## Executive summary", "ai/off");

    // --- DETERMINISM: same audit + locale -> byte-identical report -------------
    if (buildProspectReport(bad, { locale: "en" }) !== buildProspectReport(bad, { locale: "en" })) errs.push("not deterministic (en)");
    if (buildProspectReport(bad, { locale: "ar" }) !== buildProspectReport(bad, { locale: "ar" })) errs.push("not deterministic (ar)");
    // Non-en locale (and missing locale) -> Arabic (RTL-first default).
    if (!buildProspectReport(good, {}).includes("dir=\"rtl\"")) errs.push("missing locale did not default to ar/RTL");
    if (!buildProspectReport(good, { locale: "fr" }).includes("dir=\"rtl\"")) errs.push("unknown locale did not default to ar/RTL");

    console.log(errs.length ? "FAIL: " + errs.join("; ") : "PROSPECT_REPORT_OK");
  ' "${ENGINE}/report.js" "${FIX}/audit-good.json" "${FIX}/audit-bad.json" "${FIX}/audit-unreachable.json")"
  if [[ "${OUT}" == *PROSPECT_REPORT_OK* ]]; then _pass "prospect report: bilingual (ar RTL-first/en), verdict+tier, 5-score table, prioritised findings, AI summary, footer; deterministic"
  else _fail "prospect report wrong — ${OUT}"; fi
else
  _skip "prospect report (node not available)"
fi

# ===========================================================================
section "PDF-EXPORT — pure Markdown->HTML core + off-by-default renderer that degrades"
# ---------------------------------------------------------------------------
# The OPTIONAL PDF export (services/seo/engine/{md-to-html,pdf-export}.js). md-to-html
# is PURE + dependency-free: a report's Markdown -> a clean, self-contained, A4
# print-ready HTML (headings, lists, blockquotes, GFM pipe tables incl. escaped \|,
# inline bold/italic/code, HTML-escaping, and the dir="rtl" passthrough Arabic reports
# carry), deterministic byte-for-byte. pdf-export is OFF BY DEFAULT: with no renderer
# it returns the HTML + degraded=true (keeping the Markdown); a PDF is produced ONLY
# via an INJECTED renderer (proving the seam without any real library or network), and
# a throwing/empty renderer degrades gracefully. No Docker, no browser, no network.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [m2hP, pdfP] = process.argv.slice(1);
    const { markdownToHtml, renderHtmlDocument, detectDir, renderInline, escapeHtml } = await import(pathToFileURL(m2hP).href);
    const { renderReportPdf, loadRenderer } = await import(pathToFileURL(pdfP).href);
    const errs = [];
    const has = (s, sub, label) => { if (!s.includes(sub)) errs.push(label + " missing [" + sub + "]"); };
    const hasnt = (s, sub, label) => { if (s.includes(sub)) errs.push(label + " unexpectedly has [" + sub + "]"); };

    const bs = String.fromCharCode(92); // a literal backslash, for the escaped-pipe cell
    const md = [
      "<div dir=" + String.fromCharCode(34) + "rtl" + String.fromCharCode(34) + ">",
      "",
      "# عنوان <Demo> & co",
      "",
      "- **URL:** https://x.example",
      "- *note* with `code`",
      "",
      "## نتائج الفئات",
      "",
      "| Category | Score |",
      "|---|---|",
      "| SEO | 80/100 |",
      "| Perf " + bs + "| edge | 50/100 |",
      "",
      "### 1. 🔴 CRITICAL — Serve over HTTPS",
      "",
      "> Use a valid cert and **redirect**.",
      "",
      "---",
      "_Generated automatically._",
      "",
      "</div>",
    ].join(String.fromCharCode(10));

    // --- md-to-html: PURE block + inline rendering ----------------------------
    const html = markdownToHtml(md);
    has(html, "<div dir=" + String.fromCharCode(34) + "rtl" + String.fromCharCode(34) + ">", "html"); // RTL wrapper passed through verbatim
    has(html, "<h1>عنوان &lt;Demo&gt; &amp; co</h1>", "html");                 // heading + HTML-escaping
    has(html, "<h2>نتائج الفئات</h2>", "html");
    has(html, "<h3>1. 🔴 CRITICAL — Serve over HTTPS</h3>", "html");           // emoji preserved
    has(html, "<strong>URL:</strong>", "html");                                // bold
    has(html, "<em>note</em>", "html"); has(html, "<code>code</code>", "html"); // italic + code
    has(html, "<ul><li>", "html");                                             // list
    has(html, "<table><thead><tr><th>Category</th><th>Score</th></tr></thead>", "html"); // table head
    has(html, "<td>Perf | edge</td>", "html");                                 // escaped pipe -> single cell
    has(html, "<blockquote><p>Use a valid cert and <strong>redirect</strong>.</p></blockquote>", "html");
    has(html, "<hr />", "html");
    hasnt(html, "<script", "html");                                            // no raw script injection

    // escapeHtml + renderInline units.
    if (escapeHtml("<a>&\"") !== "&lt;a&gt;&amp;\"") errs.push("escapeHtml wrong: " + escapeHtml("<a>&\""));
    if (renderInline("**b** _i_ `c`") !== "<strong>b</strong> <em>i</em> <code>c</code>") errs.push("renderInline wrong: " + renderInline("**b** _i_ `c`"));

    // detectDir + full document wrapper.
    if (detectDir(md) !== "rtl") errs.push("detectDir(rtl) wrong");
    if (detectDir("# plain") !== "ltr") errs.push("detectDir(ltr) wrong");
    const doc = renderHtmlDocument(md, { title: "t<>&", lang: "ar" });
    has(doc, "<!doctype html>", "doc");
    has(doc, "<html lang=" + String.fromCharCode(34) + "ar" + String.fromCharCode(34) + " dir=" + String.fromCharCode(34) + "rtl" + String.fromCharCode(34) + ">", "doc");
    has(doc, "<title>t&lt;&gt;&amp;</title>", "doc");                          // title attr-escaped
    has(doc, "@page", "doc"); has(doc, "size: A4", "doc");                     // print CSS present
    // ltr report -> ltr document, lang follows dir when not given.
    const docEn = renderHtmlDocument("# hi", { title: "x" });
    has(docEn, "<html lang=" + String.fromCharCode(34) + "en" + String.fromCharCode(34) + " dir=" + String.fromCharCode(34) + "ltr" + String.fromCharCode(34) + ">", "docEn");

    // DETERMINISM: same Markdown -> byte-identical HTML.
    if (markdownToHtml(md) !== markdownToHtml(md)) errs.push("markdownToHtml not deterministic");
    if (renderHtmlDocument(md, { title: "t" }) !== renderHtmlDocument(md, { title: "t" })) errs.push("renderHtmlDocument not deterministic");

    // --- pdf-export: OFF by default -> degrade to HTML + keep Markdown ---------
    const off = await renderReportPdf(md, { title: "t" }, { env: {} });
    if (!(off.degraded === true && off.pdf === null && off.html.includes("<html"))) errs.push("default not degraded to HTML");
    if (!off.reason || !/renderer/i.test(off.reason)) errs.push("degrade reason not helpful");

    // loadRenderer: off when unset; null (never throws) when the module is absent.
    if ((await loadRenderer({})) !== null) errs.push("loadRenderer not off by default");
    if ((await loadRenderer({ SEO_PDF_RENDERER: "pi-no-such-renderer-xyz" })) !== null) errs.push("loadRenderer missing module did not degrade");

    // --- pdf-export: an INJECTED renderer produces a PDF (no real lib/network) -
    let gotHtml = null;
    const stub = async (h) => { gotHtml = h; return Buffer.from("%PDF-1.4 stub " + h.length); };
    const on = await renderReportPdf(md, { title: "t" }, { renderPdf: stub });
    if (!(on.degraded === false && Buffer.isBuffer(on.pdf) && on.pdf.toString().startsWith("%PDF"))) errs.push("injected renderer did not yield a PDF");
    if (gotHtml === null || !gotHtml.includes("<html")) errs.push("renderer was not handed the HTML document");

    // A throwing renderer degrades gracefully (keeps Markdown/HTML, never throws).
    const boom = await renderReportPdf(md, {}, { renderPdf: async () => { throw new Error("kaboom"); } });
    if (!(boom.degraded === true && boom.pdf === null && boom.reason.includes("kaboom") && boom.html.includes("<html"))) errs.push("throwing renderer not handled");
    // An empty result also degrades.
    const empty = await renderReportPdf(md, {}, { renderPdf: async () => Buffer.alloc(0) });
    if (!(empty.degraded === true && empty.pdf === null)) errs.push("empty renderer output not handled");

    console.log(errs.length ? "FAIL: " + errs.join("; ") : "PDF_EXPORT_OK");
  ' "${ENGINE}/md-to-html.js" "${ENGINE}/pdf-export.js")"
  if [[ "${OUT}" == *PDF_EXPORT_OK* ]]; then _pass "pdf export: pure md->html (escaping/tables/blockquote/RTL/print-CSS, deterministic) + off-by-default renderer degrades; injected renderer yields PDF"
  else _fail "pdf export wrong — ${OUT}"; fi

  # store.js report-artifact round-trip: write .html (utf8) + .pdf (binary) next to
  # the .md under reports/, and latestReport picks the newest .md by timestamped name.
  tests_run=$((tests_run+1))
  TMP="$(mktemp -d)"
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [storeP, root] = process.argv.slice(1);
    const { writeReport, writeReportArtifact, latestReport, listReports } = await import(pathToFileURL(storeP).href);
    const errs = [];
    writeReport(root, "demo", "2026-05-20T00:00:00.000Z", "# old");
    const f2 = writeReport(root, "demo", "2026-05-23T00:00:00.000Z", "# new");
    const htmlF = writeReportArtifact(root, "demo", "2026-05-23T00:00:00.000Z", "html", "<html>x</html>");
    const pdfF = writeReportArtifact(root, "demo", "2026-05-23T00:00:00.000Z", "pdf", Buffer.from([0x25,0x50,0x44,0x46])); // %PDF
    if (!htmlF.endsWith(".html")) errs.push("html ext wrong: " + htmlF);
    if (!pdfF.endsWith(".pdf")) errs.push("pdf ext wrong: " + pdfF);
    if (readFileSync(htmlF, "utf8") !== "<html>x</html>") errs.push("html content wrong");
    const pdfBytes = readFileSync(pdfF);
    if (!(pdfBytes.length === 4 && pdfBytes.toString("ascii") === "%PDF")) errs.push("pdf bytes wrong");
    // latestReport returns the NEWEST .md only (not html/pdf siblings).
    const latest = latestReport(root, "demo");
    if (latest !== f2) errs.push("latestReport not newest md: " + latest);
    if (listReports(root, "demo").length !== 2) errs.push("listReports count: " + listReports(root, "demo").length);
    // a bad extension is rejected (no path tricks).
    let threw = 0; try { writeReportArtifact(root, "demo", "2026-05-23T00:00:00.000Z", "../x", "y"); } catch { threw = 1; }
    if (!threw) errs.push("bad extension not rejected");
    console.log(errs.length ? "FAIL: " + errs.join("; ") : "ARTIFACT_OK");
  ' "${ENGINE}/store.js" "${TMP}")"
  rm -rf "${TMP}"
  if [[ "${OUT}" == *ARTIFACT_OK* ]]; then _pass "store: writeReportArtifact (.html utf8 / .pdf binary) + latestReport/listReports round-trip"
  else _fail "store artifact logic wrong — ${OUT}"; fi

  # END-TO-END via the audit.js CLI (the seo-auditor container ENTRYPOINT): from a
  # stored audit it builds the prospect report and writes the .md + .html ALWAYS.
  # With no renderer (default) NO .pdf is produced (degraded). With SEO_PDF_RENDERER
  # pointing at a tiny LOCAL renderer script, loadRenderer dynamically imports it and
  # a real .pdf is written — proving the full opt-in chain (no real lib, no network).
  tests_run=$((tests_run+1))
  TMP="$(mktemp -d)"
  mkdir -p "${TMP}/store/latest"
  cp "${FIX}/audit-bad.json" "${TMP}/store/latest/demo.json"
  # A minimal renderer script honouring the documented contract (html -> PDF Buffer).
  cat > "${TMP}/renderer.mjs" <<'JS'
export async function htmlToPdf(html) {
  return Buffer.from("%PDF-1.4\n% e2e " + html.length + "\n%%EOF");
}
JS
  # Default: degrades to HTML (no .pdf).
  node "${ENGINE}/audit.js" report-pdf --name demo --root "${TMP}/store" --locale en >/dev/null 2>&1
  N_PDF_OFF=$(ls "${TMP}/store/reports/" 2>/dev/null | grep -c '\.pdf$' || true)
  N_HTML=$(ls "${TMP}/store/reports/" 2>/dev/null | grep -c '\.html$' || true)
  N_MD=$(ls "${TMP}/store/reports/" 2>/dev/null | grep -c '\.md$' || true)
  # Opt-in: a real .pdf is written, starting with the PDF magic bytes.
  SEO_PDF_RENDERER="${TMP}/renderer.mjs" node "${ENGINE}/audit.js" report-pdf --name demo --root "${TMP}/store" --locale en >/dev/null 2>&1
  PDF_FILE="$(ls "${TMP}/store/reports/"*.pdf 2>/dev/null | head -n1 || true)"
  E2E_ERR=""
  [[ "${N_MD}" -ge 1 ]]   || E2E_ERR+="no .md written; "
  [[ "${N_HTML}" -ge 1 ]] || E2E_ERR+="no .html written; "
  [[ "${N_PDF_OFF}" -eq 0 ]] || E2E_ERR+="a .pdf was written with NO renderer; "
  [[ -n "${PDF_FILE}" ]]  || E2E_ERR+="no .pdf written with a renderer; "
  if [[ -n "${PDF_FILE}" ]] && ! head -c 5 "${PDF_FILE}" | grep -q '%PDF'; then E2E_ERR+="pdf lacks %PDF magic; "; fi
  rm -rf "${TMP}"
  if [[ -z "${E2E_ERR}" ]]; then _pass "report-pdf CLI: md+html always; .pdf only with SEO_PDF_RENDERER (real dynamic import, %PDF bytes)"
  else _fail "report-pdf CLI wrong — ${E2E_ERR}"; fi
else
  _skip "pdf export (node not available)"
fi

# ===========================================================================
section "SITEMAP + METADATA — bilingual (hreflang) + single-locale degrade"
# ---------------------------------------------------------------------------
SEOLIB="${MOD}/files/nextjs-app/lib/seo"
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [cfgP, smP, robP, metaP] = process.argv.slice(1);
    const { seoConfig } = await import(pathToFileURL(cfgP).href);
    const { buildSitemapEntries } = await import(pathToFileURL(smP).href);
    const { buildRobots } = await import(pathToFileURL(robP).href);
    const { buildMetadata } = await import(pathToFileURL(metaP).href);
    const errs = [];
    const cfg = seoConfig({ SEO_SITE_URL:"https://teeth.example.com/", SEO_SITE_NAME:"Happy Teeth", NEXT_PUBLIC_DEFAULT_LOCALE:"ar" });
    if (cfg.base !== "https://teeth.example.com") errs.push("base not trimmed: "+cfg.base);
    if (!cfg.isLocalized) errs.push("default not localized (ar,en)");

    const sm = buildSitemapEntries(cfg, ["/","/about"], new Date("2026-05-23T00:00:00Z"));
    const urls = sm.map(e=>e.url);
    for (const u of ["https://teeth.example.com/ar","https://teeth.example.com/en","https://teeth.example.com/ar/about","https://teeth.example.com/en/about"])
      if (!urls.includes(u)) errs.push("sitemap missing "+u);
    const langs = sm[0].alternates && sm[0].alternates.languages || {};
    for (const k of ["ar","en","x-default"]) if (!langs[k]) errs.push("hreflang missing "+k);

    // robots references the sitemap + disallows /account (auth cooperation) + /api.
    const r = buildRobots(cfg);
    if (r.sitemap !== "https://teeth.example.com/sitemap.xml") errs.push("robots sitemap wrong");
    const dis = JSON.stringify(r.rules[0].disallow);
    if (!dis.includes("/api/") || !dis.includes("/account")) errs.push("robots disallow wrong: "+dis);

    // metadata: locale-prefixed canonical + hreflang map.
    const meta = buildMetadata(cfg, { locale:"en", path:"/about", title:"About" });
    if (meta.alternates.canonical !== "https://teeth.example.com/en/about") errs.push("canonical wrong: "+meta.alternates.canonical);
    if (!meta.alternates.languages || !meta.alternates.languages["x-default"]) errs.push("meta hreflang missing");
    if (meta.openGraph.locale !== "en") errs.push("og.locale wrong");
    if (meta.openGraph.url !== "https://teeth.example.com/en/about") errs.push("og.url wrong");

    // single-locale: no prefix, no alternates.
    const cfg1 = seoConfig({ SEO_SITE_URL:"https://x.example", NEXT_PUBLIC_DEFAULT_LOCALE:"en", SEO_LOCALES:"en" });
    if (cfg1.isLocalized) errs.push("single-locale flagged localized");
    const sm1 = buildSitemapEntries(cfg1, ["/"]);
    if (sm1[0].url !== "https://x.example" || "alternates" in sm1[0]) errs.push("single-locale sitemap wrong: "+JSON.stringify(sm1[0]));
    const meta1 = buildMetadata(cfg1, { path:"/" });
    if ("languages" in meta1.alternates) errs.push("single-locale meta has languages");

    // unconfigured still renders with a safe absolute fallback.
    const cfg0 = seoConfig({ NEXT_PUBLIC_DEFAULT_LOCALE:"ar" });
    if (cfg0.configured) errs.push("unconfigured marked configured");
    if (buildSitemapEntries(cfg0).length === 0) errs.push("unconfigured sitemap empty");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "SITEMAP_OK");
  ' "${SEOLIB}/config.js" "${SEOLIB}/sitemap-data.js" "${SEOLIB}/robots-data.js" "${SEOLIB}/metadata.js")"
  if [[ "${OUT}" == *SITEMAP_OK* ]]; then _pass "sitemap/metadata: bilingual hreflang + single-locale degrade + safe fallback"
  else _fail "sitemap/metadata wrong — ${OUT}"; fi
else
  _skip "sitemap/metadata logic (node not available)"
fi

# ===========================================================================
section "FILE PLACEMENT — per-base SEO assets; STRICTLY ADDITIVE (no collisions)"
# ---------------------------------------------------------------------------
for base in nextjs-app fullstack; do
  if [[ "${base}" == "fullstack" ]]; then root="${MOD}/files/fullstack/frontend"; else root="${MOD}/files/nextjs-app"; fi
  exists "${base}: app/sitemap.js"             "${root}/app/sitemap.js"
  exists "${base}: app/robots.js"              "${root}/app/robots.js"
  exists "${base}: lib/seo/config.js"          "${root}/lib/seo/config.js"
  exists "${base}: lib/seo/sitemap-data.js"    "${root}/lib/seo/sitemap-data.js"
  exists "${base}: lib/seo/robots-data.js"     "${root}/lib/seo/robots-data.js"
  exists "${base}: lib/seo/metadata.js"        "${root}/lib/seo/metadata.js"
  exists "${base}: lib/seo/structured-data.js" "${root}/lib/seo/structured-data.js"
  exists "${base}: components/StructuredData.jsx" "${root}/components/StructuredData.jsx"
  # STRICTLY ADDITIVE: it must NOT ship/replace these (would collide with base / i18n
  # / web-analytics) — this is the whole cooperation guarantee.
  absent "${base}: ships NO app/layout.jsx"   "${root}/app/layout.jsx"
  absent "${base}: ships NO app/page.jsx"      "${root}/app/page.jsx"
  absent "${base}: ships NO app/template.jsx (no web-analytics collision)" "${root}/app/template.jsx"
  absent "${base}: ships NO middleware.js (no i18n collision)" "${root}/middleware.js"
  # routes read runtime env (force-dynamic), like web-analytics.
  fhas "${base}: sitemap.js force-dynamic"  "${root}/app/sitemap.js" "force-dynamic"
  fhas "${base}: robots.js force-dynamic"   "${root}/app/robots.js"  "force-dynamic"
done
absent "no dotnet-api files subtree (frontend-only)" "${MOD}/files/dotnet-api"

# ===========================================================================
section "SERVICE COMPOSE — profile-gated, internal, no ports, one-shot, pinned"
# ---------------------------------------------------------------------------
exists "seo.compose.yml exists" "${SVC}"
if [[ -n "${PY}" ]]; then
  OUT="$(pyyaml "${SVC}" '
err = []
names = set(svcs.keys())
if names != {"seo-auditor", "seo-lighthouse"}: err.append(f"services={names}")
for n, s in svcs.items():
    if "ports" in s: err.append(n + " has host ports")
    if s.get("profiles") != ["seo"]: err.append(n + " not profile-gated [seo]")
    if s.get("security_opt") != ["no-new-privileges:true"]: err.append(n + " missing no-new-privileges")
    # one-shot: must NOT restart-loop (no always-on browser)
    if str(s.get("restart")) not in ("no", "False", "no "): err.append(n + " restart not no: " + str(s.get("restart")))
    if "build" not in s: err.append(n + " has no build")
    img = s.get("image", "")
    if img.endswith(":latest") or (img and ":" not in img.split("/")[-1]): err.append(n + " image not pinned: " + img)
    # internal-only (NOT proxy), no inbound dashboard
    if s.get("networks", []) != ["internal"]: err.append(n + " networks not [internal]: " + str(s.get("networks")))
    lim = (((s.get("deploy") or {}).get("resources") or {}).get("limits") or {}).get("memory")
    if not lim: err.append(n + " has no memory limit")
print("OK" if not err else "FAIL: " + "; ".join(err))
')"
  case "${OUT}" in
    *OK*)     tests_run=$((tests_run+1)); _pass "service compose invariants (profile/ports/networks/one-shot/pinned/mem)" ;;
    *NOYAML*) _skip "service compose invariants (PyYAML not available)" ;;
    *)        tests_run=$((tests_run+1)); _fail "service compose invariants — ${OUT}" ;;
  esac
else
  _skip "service compose invariants (python not available)"
fi
# Dockerfiles: pinned base, never latest; lighthouse pins its version.
fhas  "Dockerfile pins node:22-alpine"            "${PROJECT_ROOT}/services/seo/Dockerfile" "FROM node:22-alpine"
fhasnt "Dockerfile is NOT :latest"                "${PROJECT_ROOT}/services/seo/Dockerfile" ":latest"
fhas  "Dockerfile.lighthouse pins LIGHTHOUSE_VERSION" "${PROJECT_ROOT}/services/seo/Dockerfile.lighthouse" "LIGHTHOUSE_VERSION="
fhasnt "Dockerfile.lighthouse is NOT :latest"     "${PROJECT_ROOT}/services/seo/Dockerfile.lighthouse" ":latest"
# the lighthouse engine gets more memory than the light default (honest about Chromium)
fhas  "seo-lighthouse mem 1024M (heavier)"        "${SVC}" "1024M"
fhas  "seo-auditor mem 256M (light default)"      "${SVC}" "256M"

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
for k in ("SEO_SITE_URL","SEO_SITE_NAME","SEO_LOCALES"):
    if k not in env: err.append("env missing "+k)
print("OK" if not err else "FAIL: " + "; ".join(err))
')"
    case "${OUT}" in
      *OK*)     tests_run=$((tests_run+1)); _pass "${base}: merges SEO_* into ${WEBSVC[$base]} only (no container/ports)" ;;
      *NOYAML*) _skip "${base}: module compose invariants (PyYAML not available)" ;;
      *)        tests_run=$((tests_run+1)); _fail "${base}: module compose invariants — ${OUT}" ;;
    esac
  else
    _skip "${base}: module compose invariants (python not available)"
  fi
  fhas "${base}: per-project SEO_SITE_URL override" "${frag}" '${__ENVPREFIX__SEO_SITE_URL:-${SEO_SITE_URL:-}}'
done

# ===========================================================================
section "BOOT PROFILES — the seo services are NEVER in a boot profile (no always-on)"
# ---------------------------------------------------------------------------
fhasnt "boot-profiles.conf has NO seo-auditor"   "${BOOTPROFILES}" "seo-auditor"
fhasnt "boot-profiles.conf has NO seo-lighthouse" "${BOOTPROFILES}" "seo-lighthouse"

# ===========================================================================
section "STORE — append/read/trend round-trip (engine/store.js, temp dir)"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  TMP="$(mktemp -d)"
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [storeP, badP, goodP, root] = process.argv.slice(1);
    const { appendAudit, readAudits, readLatest, listSites, trend, isValidName } = await import(pathToFileURL(storeP).href);
    const errs = [];
    if (isValidName("1bad")) errs.push("accepted 1bad name");
    if (!isValidName("happy-teeth")) errs.push("rejected happy-teeth");
    const a1 = JSON.parse(readFileSync(badP,"utf8"));
    const a2 = JSON.parse(readFileSync(goodP,"utf8"));
    a1.name = "demo"; a2.name = "demo";
    a1.timestamp = "2026-05-20T00:00:00.000Z"; a2.timestamp = "2026-05-23T00:00:00.000Z";
    appendAudit(root, "demo", a1);
    appendAudit(root, "demo", a2);
    const hist = readAudits(root, "demo");
    if (hist.length !== 2) errs.push("history len "+hist.length);
    const latest = readLatest(root, "demo");
    if (!latest || latest.timestamp !== a2.timestamp) errs.push("latest wrong");
    if (!listSites(root).includes("demo")) errs.push("listSites missing demo");
    const t = trend(hist);
    if (t.runs !== 2) errs.push("trend runs "+t.runs);
    if (t.categories.seo.first !== a1.scores.seo || t.categories.seo.latest !== a2.scores.seo) errs.push("trend seo wrong");
    if (t.categories.seo.delta !== (a2.scores.seo - a1.scores.seo)) errs.push("trend delta wrong");
    console.log(errs.length ? "FAIL: "+errs.join("; ") : "STORE_OK");
  ' "${ENGINE}/store.js" "${FIX}/audit-bad.json" "${FIX}/audit-good.json" "${TMP}")"
  rm -rf "${TMP}"
  if [[ "${OUT}" == *STORE_OK* ]]; then _pass "store: append/read/latest/list/trend round-trip correct"
  else _fail "store logic wrong — ${OUT}"; fi
else
  _skip "store logic (node not available)"
fi

# ===========================================================================
section "SSRF-GUARD — block private/reserved + internal hosts; allow public (engine/ssrf-guard.js)"
# ---------------------------------------------------------------------------
# Pure classifiers: every blocked IPv4 range + public IPv4; IPv6 loopback/ULA/
# link-local/IPv4-mapped + public IPv6; localhost / bare Docker name / *.internal
# / *.local + public name; and the scheme + credentials URL policy. No network.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [guardP] = process.argv.slice(1);
    const g = await import(pathToFileURL(guardP).href);
    const errs = [];
    const T = (label, got, want) => { if (got !== want) errs.push(label+" got "+JSON.stringify(got)+" want "+JSON.stringify(want)); };

    // ipv4ToInt: canonical only; non-canonical (octal/short/integer) forms refused.
    T("ipv4 loopback int", g.ipv4ToInt("127.0.0.1"), 2130706433);
    T("ipv4 octal refused", g.ipv4ToInt("0177.0.0.1"), null);
    T("ipv4 short refused",  g.ipv4ToInt("127.1"), null);
    T("ipv4 integer refused", g.ipv4ToInt("2130706433"), null);

    // Each blocked IPv4 range (0/8,10/8,CGNAT,loopback,metadata,172.16/12,192.168,multicast,reserved).
    for (const ip of ["0.0.0.0","10.0.0.1","100.64.0.1","127.0.0.1","169.254.169.254","172.16.0.1","172.31.255.255","192.168.1.1","224.0.0.1","240.0.0.1","255.255.255.255"])
      T("blockedV4 "+ip, g.isBlockedIPv4(ip), true);
    // Public IPv4 allowed (Google DNS, Cloudflare, a real CDN edge IP).
    for (const ip of ["8.8.8.8","1.1.1.1","93.184.216.34","151.101.1.140"])
      T("publicV4 "+ip, g.isBlockedIPv4(ip), false);

    // IPv6: loopback / unspecified / unique-local / link-local / IPv4-mapped blocked.
    for (const ip of ["::1","::","fc00::1","fd00:abcd::1","fe80::1","::ffff:127.0.0.1","::ffff:10.0.0.1"])
      T("blockedV6 "+ip, g.isBlockedIPv6(ip), true);
    // Public IPv6 allowed (Google + Cloudflare; mapped-public is fine).
    for (const ip of ["2001:4860:4860::8888","2606:4700:4700::1111","::ffff:8.8.8.8"])
      T("publicV6 "+ip, g.isBlockedIPv6(ip), false);

    // Internal hostnames: localhost, bare Docker service names, *.internal, *.local.
    for (const h of ["localhost","app.localhost","postgres","redis","db.internal","printer.local"])
      T("localname "+h, g.isLocalHostname(h), true);
    for (const h of ["example.com","www.example.com"])
      T("publicname "+h, g.isLocalHostname(h), false);

    // classifyHost rolls these up + catches numeric-bypass and bracketed IPv6.
    T("classify metadata blocked",      g.classifyHost("169.254.169.254").blocked, true);
    T("classify numeric-bypass blocked", g.classifyHost("2130706433").blocked, true);
    T("classify [::1] blocked",         g.classifyHost("[::1]").blocked, true);
    T("classify public host allowed",   g.classifyHost("example.com").blocked, false);

    // classifyUrl: only http/https, and never credentials-in-URL.
    T("file:// rejected",       g.classifyUrl("file:///etc/passwd").blocked, true);
    T("ftp:// rejected",        g.classifyUrl("ftp://example.com/").blocked, true);
    T("creds-in-url rejected",  g.classifyUrl("http://user:pass@example.com/").blocked, true);
    T("public https allowed",   g.classifyUrl("https://example.com/path").blocked, false);

    // allowPrivate opt-in flag parsing.
    T("allowPrivate=1 on",      g.allowPrivate({PROSPECTS_PROBE_ALLOW_PRIVATE:"1"}), true);
    T("allowPrivate default off", g.allowPrivate({}), false);

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "SSRF_CLASSIFY_OK");
  ' "${ENGINE}/ssrf-guard.js")"
  if [[ "${OUT}" == *SSRF_CLASSIFY_OK* ]]; then _pass "ssrf classifiers: IPv4/IPv6/hostname blocked vs public + scheme/credentials policy"
  else _fail "ssrf classifier logic wrong — ${OUT}"; fi

  # assertUrlAllowed: the impure gate, driven by an INJECTED resolver so there is
  # NO real DNS/network. Covers public-name allow, DNS-rebinding (name -> 127.0.0.1)
  # block, a mixed public+private answer block (one bad IP poisons the set), and the
  # PROSPECTS_PROBE_ALLOW_PRIVATE=1 opt-in permitting localhost. Also asserts the
  # thrown error is non-leaky (never echoes the internal IP a name resolved to).
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [guardP] = process.argv.slice(1);
    const { assertUrlAllowed } = await import(pathToFileURL(guardP).href);
    const errs = [];
    const resolver = (map) => async (h) => { if (map[h]) return map[h]; throw new Error("NXDOMAIN"); };
    const blocks = async (label, url, deps) => {
      try { await assertUrlAllowed(url, deps); errs.push(label+" did NOT block"); }
      catch (e) {
        if (e.code !== "SSRF_BLOCKED") errs.push(label+" wrong error code: "+e.message);
        if (/127\.0\.0\.1|10\.0\.0\.5/.test(e.message)) errs.push(label+" LEAKS resolved ip: "+e.message);
      }
    };
    const allows = async (label, url, deps) => {
      try { const r = await assertUrlAllowed(url, deps); if (!r || !Array.isArray(r.addresses)) errs.push(label+" bad return shape"); }
      catch (e) { errs.push(label+" blocked unexpectedly: "+e.message); }
    };

    // public name -> public IP : allowed.
    await allows("public name", "https://example.com/", { env:{}, resolve: resolver({ "example.com":["93.184.216.34"] }) });
    // DNS rebinding: public-looking name resolves to loopback : blocked + non-leaky.
    await blocks("rebind->127.0.0.1", "https://evil.test/", { env:{}, resolve: resolver({ "evil.test":["127.0.0.1"] }) });
    // mixed public + private answer : blocked (every resolved IP must be public).
    await blocks("mixed public+private", "https://evil.test/", { env:{}, resolve: resolver({ "evil.test":["8.8.8.8","10.0.0.5"] }) });
    // opt-in escape hatch allows an internal target on purpose.
    await allows("opt-in localhost", "http://localhost:3000/", { env:{ PROSPECTS_PROBE_ALLOW_PRIVATE:"1" }, resolve: resolver({ "localhost":["127.0.0.1"] }) });
    // ...but the opt-in NEVER relaxes the scheme/credentials policy.
    await blocks("opt-in still rejects creds", "http://u:p@10.0.0.1/", { env:{ PROSPECTS_PROBE_ALLOW_PRIVATE:"1" }, resolve: resolver({}) });

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "SSRF_GATE_OK");
  ' "${ENGINE}/ssrf-guard.js")"
  if [[ "${OUT}" == *SSRF_GATE_OK* ]]; then _pass "ssrf gate (injected resolver): public allowed; rebinding+mixed blocked (non-leaky); allow-private opt-in"
  else _fail "ssrf gate logic wrong — ${OUT}"; fi

  # probeUrl WIRING: the guard is actually enforced by the probe (not just unit-pure).
  # Driven by an injected fetchImpl + resolver (NO real network, NO real DNS). Covers
  # (1) an allowed public probe, (2) a blocked operator URL refused BEFORE any fetch,
  # and (3) a public URL that 302-redirects to the cloud-metadata IP — the hop is
  # re-checked and refused, the internal host is NEVER fetched, and probeUrl never throws.
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [probeP] = process.argv.slice(1);
    const { probeUrl } = await import(pathToFileURL(probeP).href);
    const errs = [];
    const now = () => Date.parse("2026-05-23T00:00:00Z");
    // Injected resolver: the one public name -> a public IP; anything else NXDOMAINs.
    const resolve = async (h) => { if (h === "example.com") return ["93.184.216.34"]; throw new Error("NXDOMAIN"); };
    const html = "<!doctype html><html lang=\"en\"><head><title>Hello World Home Page</title>" +
      "<meta name=\"description\" content=\"A small but perfectly descriptive page about us.\">" +
      "</head><body><h1>Hi</h1></body></html>";

    // (1) ALLOWED: public name -> public IP -> normal 200 audit; the stub IS fetched.
    let okCalls = 0;
    const fetchOk = async () => { okCalls++; return { status: 200, headers: new Map(), text: async()=>html }; };
    const aOk = await probeUrl("demo", "https://example.com/", { fetchImpl: fetchOk, resolve, now });
    if (aOk.ok !== true) errs.push("allowed: ok!=true (status="+aOk.status+")");
    if (aOk.engine !== "probe") errs.push("allowed: engine!=probe");
    if (okCalls < 1) errs.push("allowed: never fetched (guard wrongly blocked a public URL)");

    // (2) BLOCKED INITIAL: operator URL is the cloud-metadata IP -> refused, NO fetch.
    let metaCalls = 0;
    const fetchMeta = async () => { metaCalls++; return { status: 200, headers: new Map(), text: async()=>html }; };
    const aMeta = await probeUrl("demo", "http://169.254.169.254/latest/meta-data/", { fetchImpl: fetchMeta, resolve, now });
    if (aMeta.ok !== false) errs.push("blocked-initial: ok!=false");
    if (!String(aMeta.status).includes("blocked by SSRF guard")) errs.push("blocked-initial: status="+aMeta.status);
    if (metaCalls !== 0) errs.push("blocked-initial: fetched a blocked target "+metaCalls+" time(s)");

    // (3) BLOCKED ON REDIRECT: 302 -> http://169.254.169.254/ . The metadata host must
    //     NEVER be fetched, probeUrl must not throw, and the audit must record the block.
    let calls = 0; const seen = [];
    const fetch302 = async (u) => { calls++; seen.push(String(u));
      return { status: 302, headers: new Map([["location", "http://169.254.169.254/"]]), text: async()=>"" }; };
    let threw = 0; let aRdr;
    try { aRdr = await probeUrl("demo", "https://example.com/", { fetchImpl: fetch302, resolve, now }); }
    catch (e) { threw++; }
    if (threw) errs.push("redirect: probeUrl threw (it must NEVER throw)");
    else {
      if (aRdr.ok !== false) errs.push("redirect: ok!=false");
      if (!String(aRdr.status).includes("blocked by SSRF guard")) errs.push("redirect: status="+aRdr.status);
    }
    if (calls !== 1) errs.push("redirect: fetched "+calls+" time(s) (want 1 — the metadata target must NOT be fetched)");
    if (seen.some((u)=>u.includes("169.254.169.254"))) errs.push("redirect: FETCHED the internal redirect target");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "PROBE_SSRF_OK");
  ' "${ENGINE}/probe.js")"
  if [[ "${OUT}" == *PROBE_SSRF_OK* ]]; then _pass "probeUrl wiring: guard blocks the initial URL + a 302->internal redirect; never fetches a blocked host; never throws"
  else _fail "probeUrl ssrf wiring wrong — ${OUT}"; fi

  # probeUrl SIZE CAP: an over-cap response is abandoned (a failed audit), never
  # buffered whole (the Pi's OOM guard) and never thrown. Driven by an injected fetch
  # whose body / declared length exceeds the small deps.maxBytes we pass; a normal page
  # still produces a healthy audit.
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [probeP] = process.argv.slice(1);
    const { probeUrl } = await import(pathToFileURL(probeP).href);
    const errs = [];
    const now = () => Date.parse("2026-05-23T00:00:00Z");
    const resolve = async (h) => { if (h === "example.com") return ["93.184.216.34"]; throw new Error("NXDOMAIN"); };
    const small = "<!doctype html><html lang=\"en\"><head><title>Tiny ok page here</title></head><body><h1>Hi</h1></body></html>";
    const huge = "<html>" + "x".repeat(50000) + "</html>";
    // (1) Over-cap via the res.text() fallback (Map headers carry no content-length).
    let threw = 0; let aBig;
    try { aBig = await probeUrl("demo", "https://example.com/", { fetchImpl: async()=>({ status:200, headers:new Map(), text:async()=>huge }), resolve, now, maxBytes: 1000 }); }
    catch { threw++; }
    if (threw) errs.push("toobig: threw (must never throw)");
    else if (aBig.ok !== false) errs.push("toobig: ok!=false (cap not enforced)");
    // (2) A declared content-length over the cap -> refused WITHOUT reading the body.
    let readBody = 0;
    const aDecl = await probeUrl("demo", "https://example.com/", { fetchImpl: async()=>({ status:200, headers:new Map([["content-length","999999"]]), text:async()=>{ readBody++; return huge; } }), resolve, now, maxBytes: 1000 });
    if (aDecl.ok !== false) errs.push("declared: ok!=false");
    if (readBody !== 0) errs.push("declared: read the body despite an over-cap content-length");
    // (3) Under the cap still produces a normal, healthy audit.
    const aOk = await probeUrl("demo", "https://example.com/", { fetchImpl: async()=>({ status:200, headers:new Map(), text:async()=>small }), resolve, now, maxBytes: 1000000 });
    if (aOk.ok !== true) errs.push("undercap: ok!=true (a normal page was wrongly rejected)");
    console.log(errs.length ? "FAIL: "+errs.join("; ") : "PROBE_CAP_OK");
  ' "${ENGINE}/probe.js")"
  if [[ "${OUT}" == *PROBE_CAP_OK* ]]; then _pass "probeUrl size cap: over-cap (body + declared length) -> failed audit, never buffered/thrown; under-cap passes"
  else _fail "probeUrl size cap wrong — ${OUT}"; fi
else
  _skip "ssrf-guard (node not available)"
fi

# ===========================================================================
section "WIRING — .env, scripts, lib, cron, presets, discovery, sites example"
# ---------------------------------------------------------------------------
# .env.example SEO section + the AI seam keys (all optional, off by default).
fhas ".env.example has SEO section"        "${ENVX}" "SEO & SITE QUALITY"
fhas ".env.example has AI_PROVIDER="       "${ENVX}" "AI_PROVIDER="
fhas ".env.example has AI_API_KEY="        "${ENVX}" "AI_API_KEY="
fhas ".env.example has SEO_DATA_DIR="      "${ENVX}" "SEO_DATA_DIR="
# OPTIONAL PDF export — opt-in env documented + off by default (blank).
fhas ".env.example has SEO_PDF_RENDERER="  "${ENVX}" "SEO_PDF_RENDERER="
fhas ".env.example has SEO_REPORT_LOCALE=" "${ENVX}" "SEO_REPORT_LOCALE="
# Helper + lib + cron syntax.
tests_run=$((tests_run+1)); if bash -n "${HELPER}" 2>/dev/null; then _pass "seo.sh syntax ok"; else _fail "seo.sh syntax error"; fi
tests_run=$((tests_run+1)); if bash -n "${LIB}" 2>/dev/null; then _pass "seo-lib.sh syntax ok"; else _fail "seo-lib.sh syntax error"; fi
tests_run=$((tests_run+1)); if bash -n "${CRON}" 2>/dev/null; then _pass "seo-install-cron.sh syntax ok"; else _fail "seo-install-cron.sh syntax error"; fi
# seo.sh arg validation (no docker needed: action/engine validated before need_docker).
ok "seo.sh rejects a bad action"  bash -c '! "'"${HELPER}"'" bogus >/dev/null 2>&1'
ok "seo.sh rejects a bad engine"  bash -c '! "'"${HELPER}"'" audit foo --engine chrome >/dev/null 2>&1'
ok "seo.sh help works"            bash -c '"'"${HELPER}"'" help >/dev/null 2>&1'
# seo-lib pure logic (sourced).
ok "seo-lib: valid action audit"  bash -c '. "'"${LIB}"'"; seo_valid_action audit'
ok "seo-lib: valid action pdf"    bash -c '. "'"${LIB}"'"; seo_valid_action pdf'
no "seo-lib: rejects bad action"  bash -c '. "'"${LIB}"'"; seo_valid_action bogus'
ok "seo-lib: valid engines"       bash -c '. "'"${LIB}"'"; seo_valid_engine probe && seo_valid_engine lighthouse'
no "seo-lib: rejects bad engine"  bash -c '. "'"${LIB}"'"; seo_valid_engine chrome'
ok "seo-lib: valid name"          bash -c '. "'"${LIB}"'"; seo_valid_name happy-teeth'
no "seo-lib: rejects trailing -"  bash -c '. "'"${LIB}"'"; seo_valid_name bad-'
# seo-lib sites parsing (temp file).
tests_run=$((tests_run+1))
PARSE="$(bash -c '
  . "'"${LIB}"'"
  t="$(mktemp)"
  printf "# c\nmy-portfolio https://example.com\nBADNAME https://x\n" > "$t"
  seo_parse_sites "$t" 2>/dev/null
  echo "URL:$(seo_lookup_url "$t" my-portfolio 2>/dev/null)"
  rm -f "$t"
')"
if [[ "${PARSE}" == *"my-portfolio https://example.com"* && "${PARSE}" == *"URL:https://example.com"* && "${PARSE}" != *"BADNAME"* ]]; then
  _pass "seo-lib: parses sites, validates names, looks up URL"
else _fail "seo-lib sites parsing wrong — ${PARSE}"; fi
# Presets list seo-toolkit.
fhas "company-site preset lists seo-toolkit" "${PROJECT_ROOT}/templates/presets/company-site/preset.manifest" "seo-toolkit"
fhas "ecommerce preset lists seo-toolkit"    "${PROJECT_ROOT}/templates/presets/ecommerce/preset.manifest"    "seo-toolkit"
fhas "real-estate preset lists seo-toolkit"  "${PROJECT_ROOT}/templates/presets/real-estate/preset.manifest"  "seo-toolkit"
# sites example committed (and the real one is git-ignored under data/).
exists "sites.example.conf exists" "${PROJECT_ROOT}/services/seo/sites.example.conf"
# engine package.json declares ESM (so the container runs the modules unambiguously).
fhas "engine package.json is type:module" "${ENGINE}/package.json" '"type": "module"'
# OPTIONAL PDF export wiring: pure engine modules present; seo.sh exposes `pdf`; the
# auditor service passes the opt-in renderer env; the README documents the opt-in.
exists "engine md-to-html.js exists"   "${ENGINE}/md-to-html.js"
exists "engine pdf-export.js exists"   "${ENGINE}/pdf-export.js"
fhas  "seo.sh has a pdf action"        "${HELPER}" "  pdf)"
fhas  "seo.sh wires report-pdf"        "${HELPER}" "report-pdf --name"
fhas  "seo-auditor passes SEO_PDF_RENDERER" "${SVC}" "SEO_PDF_RENDERER"
fhas  "audit.js has report-pdf cmd"    "${ENGINE}/audit.js" "report-pdf"
fhas  "README documents PDF export"    "${PROJECT_ROOT}/services/seo/README.md" "Optional PDF export"
ok    "seo.sh accepts the pdf action (passes action validation)" \
      bash -c '! "'"${HELPER}"'" pdf 2>&1 | grep -qi "Unknown action"'
# Generator discovery: an implemented module is found by scanning manifests.
tests_run=$((tests_run+1))
FOUND=""
for m in "${PROJECT_ROOT}"/templates/modules/*/module.manifest; do
  [[ "$(mget "${m}" status)" == "implemented" ]] || continue
  [[ "$(mget "${m}" name)" == "seo-toolkit" ]] && FOUND=1
done
[[ -n "${FOUND}" ]] && _pass "generator discovers seo-toolkit as implemented" || _fail "seo-toolkit not discovered as implemented"

# ===========================================================================
section "SINGLE-FLIGHT LOCK — only one audit/analysis runs at a time (lock-lib.sh)"
# ---------------------------------------------------------------------------
# Portable mkdir lock: a held, live, fresh lock REFUSES a second acquire (single-flight);
# a dead-holder or age-stale lock is reclaimed; release only removes a lock WE own. The
# fallback path tested here is exactly the path used on a host WITHOUT flock.
LOCKLIB="${PROJECT_ROOT}/scripts/lib/lock-lib.sh"
exists "lock-lib.sh exists" "${LOCKLIB}"
tests_run=$((tests_run+1)); if bash -n "${LOCKLIB}" 2>/dev/null; then _pass "lock-lib.sh syntax ok"; else _fail "lock-lib.sh syntax error"; fi
LKTMP="$(mktemp -d 2>/dev/null || echo "${SCRIPT_DIR}/.lktmp.$$")"; mkdir -p "${LKTMP}"
ok "lock: fresh acquire succeeds" bash -c '. "'"${LOCKLIB}"'"; lock_acquire "'"${LKTMP}"'/a.lock"'
ok "lock: a 2nd acquire on a held (live) lock is refused — single-flight" bash -c '
  . "'"${LOCKLIB}"'"; L="'"${LKTMP}"'/sf.lock"
  lock_acquire "$L" || { echo "first acquire failed"; exit 1; }
  if lock_acquire "$L"; then echo "second acquire WRONGLY succeeded"; exit 1; fi; exit 0'
ok "lock: re-acquire after release succeeds" bash -c '
  . "'"${LOCKLIB}"'"; L="'"${LKTMP}"'/rel.lock"
  lock_acquire "$L" || exit 1; lock_release "$L"
  lock_acquire "$L" || { echo "could not re-acquire after release"; exit 1; }; exit 0'
ok "lock: reclaims a stale lock (dead holder pid)" bash -c '
  . "'"${LOCKLIB}"'"; L="'"${LKTMP}"'/stale.lock"; D="$L.d"; mkdir -p "$D"
  sleep 0.1 & DEAD=$!; wait "$DEAD" 2>/dev/null    # DEAD is now an exited pid
  echo "$DEAD" > "$D/pid"; date +%s > "$D/start"
  lock_acquire "$L" || { echo "did not reclaim a dead-pid lock"; exit 1; }; exit 0'
ok "lock: reclaims an age-stale lock (older than PI_LOCK_MAX_AGE)" bash -c '
  . "'"${LOCKLIB}"'"; L="'"${LKTMP}"'/old.lock"; D="$L.d"; mkdir -p "$D"
  echo "$$" > "$D/pid"; echo "1" > "$D/start"      # our pid (alive) but ancient start
  PI_LOCK_MAX_AGE=1; lock_acquire "$L" || { echo "did not reclaim an age-stale lock"; exit 1; }; exit 0'
ok "lock: release leaves a lock we do NOT own intact" bash -c '
  . "'"${LOCKLIB}"'"; L="'"${LKTMP}"'/owned.lock"; D="$L.d"; mkdir -p "$D"
  echo "1" > "$D/pid"; date +%s > "$D/start"       # owner pid 1 (not us)
  lock_release "$L"
  if [ ! -d "$D" ]; then echo "release removed a foreign-owned lock"; exit 1; fi
  rm -rf "$D"; exit 0'
rm -rf "${LKTMP}" 2>/dev/null || true
# WIRING: the audit + analyze actions source lock-lib and take the single-flight lock.
fhas "seo.sh sources lock-lib"             "${HELPER}" "lib/lock-lib.sh"
fhas "seo.sh audit takes the lock"         "${HELPER}" 'lock_acquire "${AUDIT_LOCK}"'
fhas "prospects.sh sources lock-lib"       "${PROJECT_ROOT}/scripts/prospects.sh" "lib/lock-lib.sh"
fhas "prospects.sh analyze takes the lock" "${PROJECT_ROOT}/scripts/prospects.sh" 'lock_acquire "${ANALYZE_LOCK}"'

# ===========================================================================
section "REAUDIT — scheduled re-audit + diff alert wiring (opt-in monitoring)"
# ---------------------------------------------------------------------------
exists "diff engine module present"            "${ENGINE}/diff.js"
ok  "seo-lib: reaudit is a valid action"       bash -c '. "'"${LIB}"'"; seo_valid_action reaudit'
ok  "seo.sh accepts the reaudit action"        bash -c '. "'"${LIB}"'"; seo_valid_action reaudit'
fhas "seo.sh has a reaudit action"             "${HELPER}" "  reaudit)"
fhas "seo.sh reaudit drives the engine reaudit" "${HELPER}" "seo-auditor reaudit --name"
fhas "seo.sh reaudit is single-flight (audit lock)" "${HELPER}" 'lock_acquire "${AUDIT_LOCK}"'
# The engine subcommand: re-probe, diff, report-with-changes, alert only on meaningful change.
fhas "audit.js has a reaudit subcommand"       "${ENGINE}/audit.js" "cmd === 'reaudit'"
fhas "reaudit attaches the diff to the report" "${ENGINE}/audit.js" "diff: delta"
fhas "reaudit alerts only on meaningful change" "${ENGINE}/audit.js" "isMeaningfulChange(delta)"
fhas "reaudit reuses the gated SEO notifier"   "${ENGINE}/audit.js" "notify(root"
# report.js renders the diff via the shared diff engine.
fhas "report.js imports the diff summary"      "${ENGINE}/report.js" "summarizeDiff"
fhas "report.js renders the changes section"   "${ENGINE}/report.js" "Changes since last audit"
# .env.example documents the opt-in re-audit monitoring schedule.
fhas ".env.example documents reaudit monitoring" "${ENVX}" "reaudit"

# ===========================================================================
section "CONTENT-IDEAS — engine + store reader + CLI wiring (reads local data only)"
# ---------------------------------------------------------------------------
exists "content-ideas engine module present"     "${ENGINE}/content-ideas.js"
fhas  "content-ideas reuses the SEO ai.js seam"  "${ENGINE}/content-ideas.js" "getAiProvider, parseAiJson"
fhas  "content-ideas reuses rules.analyze (pure)" "${ENGINE}/content-ideas.js" "from './rules.js'"
fhas  "store.js exports a bounded cross-site reader" "${ENGINE}/store.js" "export function readRecentAuditsAcrossSites"
fhas  "audit.js has a content-ideas subcommand"  "${ENGINE}/audit.js" "cmd === 'content-ideas'"
fhas  "audit.js gathers across sites (bounded)"  "${ENGINE}/audit.js" "readRecentAuditsAcrossSites(root"
fhas  "audit.js folds the prospects store best-effort" "${ENGINE}/audit.js" "readProspectsAuditsBestEffort"
ok    "seo-lib: content-ideas is a valid action" bash -c '. "'"${LIB}"'"; seo_valid_action content-ideas'
fhas  "seo.sh has a content-ideas action"        "${HELPER}" "  content-ideas)"
fhas  "seo.sh drives the engine content-ideas"   "${HELPER}" "seo-auditor content-ideas"
fhas  ".env.example documents content-ideas"     "${ENVX}" "content-ideas"
fhas  ".env.example has SEO_IDEAS_PER_SITE="     "${ENVX}" "SEO_IDEAS_PER_SITE="

# Store reader is BOUNDED to last-N per site (real temp dir, no Docker).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
    import { tmpdir } from "node:os";
    import { join } from "node:path";
    const [storeP] = process.argv.slice(1);
    const { readRecentAuditsAcrossSites } = await import(pathToFileURL(storeP).href);
    const errs = [];
    const root = mkdtempSync(join(tmpdir(), "seo-ideas-"));
    mkdirSync(join(root, "audits"), { recursive: true });
    const row = (name, i) => JSON.stringify({ schema:1, name, timestamp:"2026-05-0"+i+"T00:00:00Z", ok:true, scores:{seo:50} });
    // site-a: 7 audits; site-b: 2 audits.
    writeFileSync(join(root,"audits","site-a.jsonl"), [1,2,3,4,5,6,7].map((i)=>row("site-a",i)).join("\n")+"\n");
    writeFileSync(join(root,"audits","site-b.jsonl"), [1,2].map((i)=>row("site-b",i)).join("\n")+"\n");
    const all = readRecentAuditsAcrossSites(root, { perSite: 5 });
    // bounded: 5 (site-a, last 5) + 2 (site-b) = 7.
    if (all.length !== 7) errs.push("bounded reader count "+all.length+" (want 7)");
    const aCount = all.filter((a)=>a.name==="site-a").length;
    if (aCount !== 5) errs.push("site-a not bounded to 5: "+aCount);
    console.log(errs.length ? "FAIL: "+errs.join("; ") : "STORE_READER_OK");
  ' "${ENGINE}/store.js")"
  if [[ "${OUT}" == *STORE_READER_OK* ]]; then _pass "store reader: recent audits across sites, BOUNDED to last-N per site (temp dir)"
  else _fail "store reader wrong — ${OUT}"; fi
else
  _skip "store reader (node not available)"
fi

# ===========================================================================
section "PANEL-WIRING — additive report section + CLI/gating wiring (opt-in)"
# ---------------------------------------------------------------------------
exists "specialists engine module present"        "${ENGINE}/specialists.js"
# buildProspectReport renders the panel ONLY when a bundle is supplied (strictly additive).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [reportP, spP, badP] = process.argv.slice(1);
    const { buildProspectReport } = await import(pathToFileURL(reportP).href);
    const { runSpecialistPanel } = await import(pathToFileURL(spP).href);
    const bad = JSON.parse(readFileSync(badP, "utf8"));
    const errs = [];
    const bundle = await runSpecialistPanel(bad, {}, {});
    const en = buildProspectReport(bad, { locale:"en", panel: bundle });
    if (!en.includes("## Specialist panel")) errs.push("en: no panel section");
    if (!en.includes("#1 priority")) errs.push("en: no #1 priority");
    if (!en.includes("Performance analyst")) errs.push("en: no specialist role");
    const ar = buildProspectReport(bad, { locale:"ar", panel: bundle });
    if (!ar.includes("تحليل فريق الخبراء")) errs.push("ar: no panel section");
    // ADDITIVE: no panel supplied => section absent (report unchanged).
    if (buildProspectReport(bad, { locale:"en" }).includes("Specialist panel")) errs.push("section present without a panel");
    // also honoured when attached to the audit object.
    if (!buildProspectReport({ ...bad, panel: bundle }, { locale:"en" }).includes("## Specialist panel")) errs.push("attached panel not rendered");
    console.log(errs.length ? "FAIL: "+errs.join("; ") : "PANEL_REPORT_OK");
  ' "${ENGINE}/report.js" "${ENGINE}/specialists.js" "${FIX}/audit-bad.json")"
  if [[ "${OUT}" == *PANEL_REPORT_OK* ]]; then _pass "report: additive bilingual 'Specialist panel' section (absent without a panel)"
  else _fail "panel report section wrong — ${OUT}"; fi
else
  _skip "panel report section (node not available)"
fi
# Wiring: report imports the renderer; CLI gates on --panel / SEO_AI_PANEL; alert shows #1.
fhas "report.js imports renderPanelSection"      "${ENGINE}/report.js" "renderPanelSection"
fhas "audit.js runs the specialist panel"        "${ENGINE}/audit.js" "runSpecialistPanel(audit"
fhas "audit.js gates panel on --panel/SEO_AI_PANEL" "${ENGINE}/audit.js" "SEO_AI_PANEL"
fhas "alert.js surfaces the #1 panel risk line"  "${PROJECT_ROOT}/services/prospects/engine/alert.js" "panelTopRiskLine"
fhas "run-analysis gates the panel (opts.panel)" "${PROJECT_ROOT}/services/prospects/engine/run-analysis.js" "deps.runPanel"
fhas "seo.sh has a --panel flag"                 "${HELPER}" "--panel)"
fhas "seo.sh forwards --panel to the auditor"    "${HELPER}" "extra+=(--panel)"
fhas ".env.example documents SEO_AI_PANEL + cost" "${ENVX}" "SEO_AI_PANEL="
fhas ".env.example states the panel call cost"    "${ENVX}" "ADDITIONAL calls"

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
