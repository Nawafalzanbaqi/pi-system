#!/usr/bin/env bash
# ===========================================================================
# pi-system — CLIENT PROSPECT ORGANIZER test harness
# ---------------------------------------------------------------------------
# Exercises the prospect organizer ENGINE + helper + SERVICE entirely WITHOUT
# Docker, network, a browser, or any AI call — mirroring tests/{seo,analytics,bot,
# ctl,startup,mem-budget,health-monitor,preflight}/run.sh. Pure logic + the real
# on-disk files + fixtures; it never mutates the repo (only a throwaway temp dir).
#
# Coverage (each maps to a real way this feature could go wrong):
#   * PIPELINE       -> pipeline.js: create + validated status TRANSITIONS, notes,
#                       follow-up set/clear, slug/validation (the state machine)
#   * FOLLOW-UPS     -> followups.js: due-date logic on fixed dates (overdue/today/
#                       future/closed-excluded) — reminders are to the OPERATOR
#   * STORE          -> store.js: loadDb/saveDb/uniqueId/list/writeReport round-trip
#   * ANALYZE-REUSE  -> analyze.js REUSES services/seo (probe via a MOCKED fetch — NO
#                       real network); produces a report; NO parallel analyzer exists
#   * REPORT         -> report generation from a FIXTURE audit (reuses SEO rules+report)
#   * AI-GATING      -> the reused AI seam stays inert without a key (mocked fetch
#                       NOT called); enriches only with a key — NO real call
#   * DECISION-ASSIST-> decision-assist.js: OPTIONAL, env-gated AI advice reusing the
#                       SAME ai.js provider seam. Inert without a key (mocked fetch NOT
#                       called); with a key returns a validated { leadScore 0..100,
#                       nextAction (FIXED allowlist), rationale }; an off-allowlist or
#                       contact-like action is REJECTED and safe-defaulted; a thrown/
#                       empty reply degrades safely; it only ADVISES — recordAssist
#                       stores ai_assist WITHOUT changing pipeline status. Never contacts.
#   * ALERT-NOTIFY   -> alert.js formatProspectAlert/Summary: a PURE, deterministic,
#                       BILINGUAL operator heads-up (client name, URL, overall+tier,
#                       biggest-win line, top 3 findings, the AI lead score WHEN present,
#                       the saved report path, and an operator-only boundary line); AND
#                       notify.js notifyAnalysis delivers it through the SAME seam
#                       (PROSPECTS_NOTIFY_CMD / Uptime-Kuma) — message on stdin, label as
#                       $1 — silent-by-default (writes last-analysis-alert.txt), never to
#                       the prospect (no prospect address anywhere in the path)
#   * TEMPLATES      -> templates.js: draft rendering (kinds, langs, placeholders)
#   * NO-SEND/SCRAPE -> ASSERTS the absence of any outreach-send or platform-scrape
#                       code path (zero deps, no transport/scraper libs, no such
#                       action/subcommand) — the architectural boundary
#   * SERVICE COMPOSE-> prospects.compose.yml: profile-gated, internal-only, NO host
#                       ports, mem limit, one-shot (restart "no"), pinned build image
#   * BOOT PROFILES  -> the prospects service is in NO boot profile (never always-on)
#   * WIRING         -> .env.example, prospects.sh + lib + cron syntax/args, Dockerfile
#
# Usage:   ./tests/prospects/run.sh        (exits non-zero on ANY failure)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every test, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

ENGINE="${PROJECT_ROOT}/services/prospects/engine"
SEOENGINE="${PROJECT_ROOT}/services/seo/engine"
SVC="${PROJECT_ROOT}/services/prospects/prospects.compose.yml"
DOCKERFILE="${PROJECT_ROOT}/services/prospects/Dockerfile"
HELPER="${PROJECT_ROOT}/scripts/prospects.sh"
LIB="${PROJECT_ROOT}/scripts/lib/prospects-lib.sh"
CRON="${PROJECT_ROOT}/scripts/prospects-install-cron.sh"
ENVX="${PROJECT_ROOT}/.env.example"
BOOTPROFILES="${PROJECT_ROOT}/infrastructure/boot-profiles.conf"
FIX="${SCRIPT_DIR}/fixtures"
SEOFIX="${PROJECT_ROOT}/tests/seo/fixtures"

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
# they resolve on every platform incl. Git-bash on Windows (see tests/seo/run.sh).
nodejs() { local body="$1"; shift; "${NODE}" --input-type=module -e "${body}" "$@" 2>&1; }

# ===========================================================================
section "PIPELINE — create + validated status TRANSITIONS + notes + follow-up"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [pipeP] = process.argv.slice(1);
    const P = await import(pathToFileURL(pipeP).href);
    const errs = [];
    const now = "2026-05-23T00:00:00.000Z";

    // create
    let r = P.createProspect({ name:"Acme Dental Clinic!", url:"https://acme.example", note:"met at expo" }, { id:"acme-dental", now });
    if (r.status !== "new") errs.push("default status not new");
    if (r.url !== "https://acme.example") errs.push("url not kept");
    if (r.notes.length !== 1) errs.push("initial note not stored");
    if (r.statusHistory.length !== 1 || r.statusHistory[0].to !== "new") errs.push("initial history wrong");

    // invalid create inputs throw
    let t=0; try { P.createProspect({ name:"" }, { id:"x", now }); } catch { t++; } if(!t) errs.push("empty name accepted");
    t=0; try { P.createProspect({ name:"X", url:"ftp://x" }, { id:"x-co", now }); } catch { t++; } if(!t) errs.push("ftp url accepted");
    t=0; try { P.createProspect({ name:"X", status:"bogus" }, { id:"x-co", now }); } catch { t++; } if(!t) errs.push("bad status accepted");

    // transition map (the funnel rules)
    if (P.canTransition("new","won")) errs.push("new->won should be invalid");
    if (P.canTransition("new","in-talks")) errs.push("new->in-talks should be invalid");
    if (!P.canTransition("new","contacted")) errs.push("new->contacted should be valid");
    if (!P.canTransition("contacted","won")) errs.push("contacted->won should be valid");
    if (P.canTransition("won","won")) errs.push("same-status is not a transition");
    if (!P.canTransition("lost","new")) errs.push("lost->new (re-engage) should be valid");

    r = P.setStatus(r, "contacted", now);
    r = P.setStatus(r, "in-talks", now);
    if (r.status !== "in-talks") errs.push("status not in-talks");
    if (r.statusHistory.length !== 3) errs.push("history not appended");
    t=0; try { P.setStatus(r, "new", now); } catch { t++; } if(!t) errs.push("invalid transition not thrown");
    t=0; try { P.setStatus(r, "in-talks", now); } catch { t++; } if(!t) errs.push("no-op transition not thrown");

    // notes + follow-up set/clear
    r = P.addNote(r, "called reception", now);
    if (r.notes.length !== 2) errs.push("note not appended");
    t=0; try { P.addNote(r, "   ", now); } catch { t++; } if(!t) errs.push("blank note accepted");
    r = P.setFollowup(r, "2026-06-01", now);
    if (r.followup !== "2026-06-01") errs.push("followup not set");
    r = P.setFollowup(r, "clear", now);
    if (r.followup !== null) errs.push("followup not cleared");
    t=0; try { P.setFollowup(r, "2026-13-40", now); } catch { t++; } if(!t) errs.push("impossible date accepted");

    // validators + slug
    if (!P.isValidId("acme-dental") || P.isValidId("1bad") || P.isValidId("bad-")) errs.push("isValidId wrong");
    if (P.slugify("Acme Dental Clinic!") !== "acme-dental-clinic") errs.push("slug wrong: "+P.slugify("Acme Dental Clinic!"));
    if (!/^[a-z]/.test(P.slugify("123 Cafe"))) errs.push("slug not letter-first: "+P.slugify("123 Cafe"));

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "PIPELINE_OK");
  ' "${ENGINE}/pipeline.js")"
  if [[ "${OUT}" == *PIPELINE_OK* ]]; then _pass "pipeline: transitions/notes/follow-up/validation correct"
  else _fail "pipeline logic wrong — ${OUT}"; fi
else
  _skip "pipeline logic (node not available)"
fi

# ===========================================================================
section "FOLLOW-UPS — due-date logic (overdue/today/future/closed) on fixed dates"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [fuP, storeP, seedP] = process.argv.slice(1);
    const F = await import(pathToFileURL(fuP).href);
    const { loadDb, listProspects } = await import(pathToFileURL(storeP).href);
    const errs = [];

    const db = JSON.parse(readFileSync(seedP, "utf8"));
    const all = Object.values(db.prospects);

    // as of 2026-05-23: only alpha-co (contacted, due 05-20) is due.
    // beta-llc future, gamma-inc won (closed), echo-co lost (closed), delta-co no date.
    let due = F.dueFollowups(all, "2026-05-23");
    if (due.length !== 1 || due[0].id !== "alpha-co") errs.push("23rd due wrong: "+JSON.stringify(due.map(x=>x.id)));

    // as of 2026-07-01: alpha-co + beta-llc due, sorted by date asc.
    due = F.dueFollowups(all, "2026-07-01");
    if (due.length !== 2 || due[0].id !== "alpha-co" || due[1].id !== "beta-llc")
      errs.push("july due wrong: "+JSON.stringify(due.map(x=>x.id)));

    // closed (won/lost) are NEVER due even with a past date.
    if (F.isDue(db.prospects["gamma-inc"], "2026-12-31")) errs.push("won counted as due");
    if (F.isDue(db.prospects["echo-co"], "2026-12-31")) errs.push("lost counted as due");
    // no follow-up date => not due.
    if (F.isDue(db.prospects["delta-co"], "2026-12-31")) errs.push("no-date counted as due");
    // future date => not due yet.
    if (F.isDue(db.prospects["beta-llc"], "2026-05-23")) errs.push("future counted as due");

    // daysUntil arithmetic (negative = overdue).
    if (F.daysUntil(db.prospects["alpha-co"], "2026-05-23") !== -3) errs.push("daysUntil overdue wrong: "+F.daysUntil(db.prospects["alpha-co"], "2026-05-23"));
    if (F.daysUntil(db.prospects["alpha-co"], "2026-05-20") !== 0) errs.push("daysUntil today wrong");

    // store loads the same dataset.
    if (Object.keys(loadDb("__nonexistent_root__").prospects).length !== 0) errs.push("missing root not empty");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "FOLLOWUPS_OK");
  ' "${ENGINE}/followups.js" "${ENGINE}/store.js" "${FIX}/prospects-seed.json")"
  if [[ "${OUT}" == *FOLLOWUPS_OK* ]]; then _pass "follow-ups: due/overdue/closed/future logic correct (operator reminder)"
  else _fail "follow-ups logic wrong — ${OUT}"; fi
else
  _skip "follow-ups logic (node not available)"
fi

# ===========================================================================
section "STORE — loadDb/saveDb/uniqueId/list/writeReport round-trip (temp dir)"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  TMP="$(mktemp -d)"
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { existsSync } from "node:fs";
    const [storeP, pipeP, root] = process.argv.slice(1);
    const S = await import(pathToFileURL(storeP).href);
    const P = await import(pathToFileURL(pipeP).href);
    const errs = [];
    const now = "2026-05-23T00:00:00.000Z";

    let db = S.loadDb(root);
    if (Object.keys(db.prospects).length !== 0) errs.push("fresh db not empty");

    const id1 = S.uniqueId(db, "Acme Dental");
    if (id1 !== "acme-dental") errs.push("uniqueId base wrong: "+id1);
    S.putProspect(db, P.createProspect({ name:"Acme Dental", url:"https://a.example" }, { id:id1, now }));
    S.saveDb(root, db);

    // unique id resolves a clash with a suffix.
    db = S.loadDb(root);
    const id2 = S.uniqueId(db, "Acme Dental");
    if (id2 !== "acme-dental-2") errs.push("uniqueId clash wrong: "+id2);
    S.putProspect(db, P.createProspect({ name:"Acme Dental", url:"https://b.example" }, { id:id2, now }));
    S.saveDb(root, db);

    db = S.loadDb(root);
    if (Object.keys(db.prospects).length !== 2) errs.push("persisted count wrong");
    if (!S.getProspect(db, "acme-dental")) errs.push("getProspect missing");
    if (S.listProspects(db).length !== 2) errs.push("list count wrong");
    if (S.listProspects(db, { status:"new" }).length !== 2) errs.push("status filter wrong");
    if (S.listProspects(db, { status:"won" }).length !== 0) errs.push("status filter empty wrong");

    const file = S.writeReport(root, "acme-dental", now, "# report\nhello");
    if (!existsSync(file)) errs.push("report file not written");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "STORE_OK");
  ' "${ENGINE}/store.js" "${ENGINE}/pipeline.js" "${TMP}")"
  rm -rf "${TMP}"
  if [[ "${OUT}" == *STORE_OK* ]]; then _pass "store: load/save/uniqueId/list/report round-trip correct"
  else _fail "store logic wrong — ${OUT}"; fi
else
  _skip "store logic (node not available)"
fi

# ===========================================================================
section "ANALYZE-REUSE — reuses services/seo via a MOCKED fetch (NO real network)"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [anaP] = process.argv.slice(1);
    const A = await import(pathToFileURL(anaP).href);
    const errs = [];

    const html = "<!doctype html><html lang=\"en\"><head><title>Acme Dental Clinic</title>" +
      "<meta name=\"description\" content=\"A friendly dental clinic in town serving families.\">" +
      "</head><body><h1>Welcome</h1><img src=\"x.png\"></body></html>";

    let calls = 0;
    const mockFetch = async (u) => { calls++; return { status: 200, headers: new Map(), text: async()=>html }; };
    // Injected DNS resolver for the probe SSRF guard: the prospect name -> a public IP,
    // so the reused probe stays offline (NO real DNS) yet still passes the guard.
    const resolve = async (h) => { if (h === "acme.example") return ["93.184.216.34"]; throw new Error("NXDOMAIN"); };

    // probe engine via the REUSED SEO probe — mocked fetch, NO real network.
    const res = await A.analyzeProspect(
      { id:"acme-dental", url:"https://acme.example" },
      {}, // env: no AI key -> rule-based
      { fetchImpl: mockFetch, now: ()=>Date.parse("2026-05-23T00:00:00Z"), resolve }
    );
    if (calls < 1) errs.push("probe never fetched (mock not used)");
    if (res.audit.engine !== "probe") errs.push("engine not probe: "+res.audit.engine);
    if (!res.report.includes("# SEO & site-quality report")) errs.push("no SEO report header (report not reused)");
    if (typeof res.counts.high !== "number") errs.push("no counts from SEO rules");
    if (!res.audit.scores || typeof res.audit.scores.seo !== "number") errs.push("no SEO scores");
    if (res.ai.enabled !== false) errs.push("AI should be off without a key");

    // probe with NO url must refuse (cannot analyze nothing).
    let threw=0; try { await A.analyzeProspect({ id:"x" }, {}, { fetchImpl: mockFetch }); } catch { threw++; }
    if (!threw) errs.push("analyze without url did not throw");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "ANALYZE_OK (fetched "+calls+")");
  ' "${ENGINE}/analyze.js")"
  if [[ "${OUT}" == *ANALYZE_OK* ]]; then _pass "analyze: reuses the SEO probe+rules+report via mocked fetch (no real network) — ${OUT#*ANALYZE_OK }"
  else _fail "analyze reuse wrong — ${OUT}"; fi
else
  _skip "analyze reuse (node not available)"
fi

# ===========================================================================
section "REPORT + AI-GATING — report from a FIXTURE audit; AI inert without a key"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [anaP, badP] = process.argv.slice(1);
    const A = await import(pathToFileURL(anaP).href);
    const audit = JSON.parse(readFileSync(badP, "utf8"));
    const errs = [];

    // report generation from a FIXTURE audit (reuses SEO rules + report renderer).
    let calledOff = 0;
    const mockOff = async () => { calledOff++; return { json: async()=>({}) }; };
    const off = await A.reportFromAudit(audit, {}, { aiFetchImpl: mockOff });
    if (!off.report.includes("# SEO & site-quality report")) errs.push("no report header");
    if (!off.report.includes("Recommendations")) errs.push("no recommendations section");
    if (off.findings.length === 0) errs.push("fixture produced no findings");
    if (off.ai.enabled !== false) errs.push("ai enabled without key");
    if (calledOff !== 0) errs.push("AI fetch called without a key (must be 0): "+calledOff);

    // WITH a key, the reused AI seam enriches -> mock fetch IS called (no real net).
    let calledOn = 0;
    const mockOn = async () => { calledOn++; return { json: async()=>({ choices:[{message:{content:"AI: add FAQ schema"}}] }) }; };
    const on = await A.reportFromAudit(audit, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }, { aiFetchImpl: mockOn });
    if (on.ai.enabled !== true) errs.push("ai not enabled with key");
    if (calledOn !== 1) errs.push("AI fetch calls with key wrong: "+calledOn);
    if (on.findings.length !== off.findings.length) errs.push("AI changed deterministic findings");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "REPORT_OK ("+off.findings.length+" findings)");
  ' "${ENGINE}/analyze.js" "${SEOFIX}/audit-bad.json")"
  if [[ "${OUT}" == *REPORT_OK* ]]; then _pass "report: generated from fixture audit; AI inert without a key, enriches only with one — ${OUT#*REPORT_OK }"
  else _fail "report/ai-gating wrong — ${OUT}"; fi
else
  _skip "report/ai-gating (node not available)"
fi

# ===========================================================================
section "DECISION-ASSIST — optional, env-gated AI advice; inert without a key; allowlisted; never contacts (mocked seam)"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [daP, pipeP] = process.argv.slice(1);
    const DA = await import(pathToFileURL(daP).href);
    const { recordAssist } = await import(pathToFileURL(pipeP).href);
    const { decisionAssist, validateAssist, normalizeAction, clampScore, NEXT_ACTIONS, DEFAULT_ACTION } = DA;
    const errs = [];

    const prospect = { id:"acme-dental", name:"Acme Dental", status:"contacted", url:"https://acme.example",
      followup:null, notes:[{ ts:"2026-05-01", text:"met at expo, owner keen on a new site" }] };
    const analysis = { scores:{ seo:21, performance:55, security:40 },
      verdict:{ overall:35, tier:"poor", opportunity:"Biggest win: add a meta description" },
      counts:{ critical:1, high:7, medium:4, low:1 }, summary:"weak site, lots to fix" };

    // Guardrail: the FIXED allowlist is exactly the four advisory actions — none of them contacts anyone.
    const want = ["research-more","prepare-offer","follow-up","deprioritize"];
    if (JSON.stringify(NEXT_ACTIONS) !== JSON.stringify(want)) errs.push("allowlist drifted: "+JSON.stringify(NEXT_ACTIONS));
    const CONTACTY = /(contact|call|email|e-mail|message|whatsapp|sms|send|dm|phone|outreach)/i;
    if (NEXT_ACTIONS.some((a)=>CONTACTY.test(a))) errs.push("allowlist contains a contact-like action!");

    // --- INERT without a key: NO network call, nothing actionable -----------
    let calledOff = 0;
    const mockOff = async () => { calledOff++; return { json: async()=>({}) }; };
    const off = await decisionAssist(prospect, analysis, {}, { aiFetchImpl: mockOff });
    if (off.enabled !== false) errs.push("assist enabled without a key");
    if (calledOff !== 0) errs.push("assist called fetch without a key (must be 0): "+calledOff);
    if (off.leadScore !== null || off.nextAction !== null) errs.push("assist produced advice without a key");

    // --- ENABLED, valid JSON: exactly one call, validated advisory record ---
    let calledOn = 0;
    const good = { leadScore: 82, nextAction: "prepare-offer", rationale: "Weak site but a keen owner — worth a tailored offer." };
    const mockOn = async () => { calledOn++; return { json: async()=>({ choices:[{ message:{ content: JSON.stringify(good) } }] }) }; };
    const on = await decisionAssist(prospect, analysis, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }, { aiFetchImpl: mockOn });
    if (on.enabled !== true) errs.push("assist not enabled with a key");
    if (calledOn !== 1) errs.push("assist fetch calls with key wrong: "+calledOn);
    if (on.leadScore !== 82) errs.push("leadScore not passed through: "+on.leadScore);
    if (on.nextAction !== "prepare-offer") errs.push("nextAction wrong: "+on.nextAction);
    if (!NEXT_ACTIONS.includes(on.nextAction)) errs.push("nextAction not in allowlist");
    if (on.advisoryOnly !== true) errs.push("not flagged advisoryOnly");
    if (on.actionFromModel !== true) errs.push("valid model action not marked actionFromModel");
    if (on.valid !== true) errs.push("valid reply not marked valid");

    // --- OFF-ALLOWLIST action is REJECTED and replaced with the safe default-
    let calledBad = 0;
    const bad = { leadScore: 95, nextAction: "call-them-now", rationale: "ignore the allowlist" };
    const mockBad = async () => { calledBad++; return { json: async()=>({ choices:[{ message:{ content: JSON.stringify(bad) } }] }) }; };
    const rej = await decisionAssist(prospect, analysis, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }, { aiFetchImpl: mockBad });
    if (rej.nextAction === "call-them-now") errs.push("off-allowlist action was ACCEPTED (must be rejected)");
    if (rej.nextAction !== DEFAULT_ACTION) errs.push("off-allowlist not defaulted to research-more: "+rej.nextAction);
    if (rej.actionFromModel !== false) errs.push("off-allowlist not flagged actionFromModel=false");
    if (rej.valid !== false) errs.push("off-allowlist not flagged invalid");
    if (CONTACTY.test(rej.nextAction)) errs.push("assist emitted a contact-like action!");

    // --- best-effort: a thrown fetch must NOT break; degrades to safe advice -
    let calledThrow = 0;
    const mockThrow = async () => { calledThrow++; throw new Error("boom"); };
    const thr = await decisionAssist(prospect, analysis, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }, { aiFetchImpl: mockThrow });
    if (calledThrow !== 1) errs.push("throw path fetch calls: "+calledThrow);
    if (thr.enabled !== true) errs.push("throw path not enabled");
    if (thr.nextAction !== DEFAULT_ACTION || thr.valid !== false) errs.push("throw path not safe-defaulted");
    if (!String(thr.error||"").includes("boom")) errs.push("throw path lost the error");

    // --- pure validators (no network) --------------------------------------
    if (clampScore(250) !== 100) errs.push("clampScore high");
    if (clampScore(-5) !== 0) errs.push("clampScore low");
    if (clampScore("abc") !== null) errs.push("clampScore non-number");
    if (normalizeAction("prepare offer") !== "prepare-offer") errs.push("normalizeAction space form");
    if (normalizeAction("FOLLOW-UP") !== "follow-up") errs.push("normalizeAction case");
    if (normalizeAction("deprioritise") !== "deprioritize") errs.push("normalizeAction british alias");
    if (normalizeAction("nuke-from-orbit") !== null) errs.push("normalizeAction accepted junk");
    const v = validateAssist({ leadScore: 70, nextAction: "follow-up", rationale: "x" }, { provider:"openai", ts:"T" });
    if (v.nextAction !== "follow-up" || v.leadScore !== 70 || v.advisoryOnly !== true) errs.push("validateAssist happy path wrong");
    const vn = validateAssist(null, { provider:"openai" });
    if (vn.nextAction !== DEFAULT_ACTION || vn.valid !== false) errs.push("validateAssist null path wrong");

    // --- recordAssist stores under ai_assist WITHOUT changing the pipeline --
    const rec = recordAssist(prospect, on, "2026-05-25T00:00:00.000Z");
    if (!rec.ai_assist || rec.ai_assist.nextAction !== "prepare-offer") errs.push("recordAssist did not store ai_assist");
    if (rec.status !== prospect.status) errs.push("recordAssist CHANGED the pipeline status (must only advise)");
    if (rec.notes !== prospect.notes) errs.push("recordAssist mutated notes");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "ASSIST_OK");
  ' "${ENGINE}/decision-assist.js" "${ENGINE}/pipeline.js")"
  if [[ "${OUT}" == *ASSIST_OK* ]]; then _pass "decision-assist: inert without a key (no fetch); allowlisted + validated advice with a key (mocked); rejects off-list/contact actions; never mutates the pipeline"
  else _fail "decision-assist wrong — ${OUT}"; fi
else
  _skip "decision-assist (node not available)"
fi

# ===========================================================================
section "DRAFTS — AI-assisted copy-paste operator drafts; inert without a key; never sends (mocked seam)"
# ---------------------------------------------------------------------------
# drafts.js turns a COMPLETED audit into copy-paste-ready OPERATOR drafts (outreach /
# referral-request / content-snippet), bilingual ar+en, REUSING the SEO AI provider seam.
# Proves: inert without a key (ZERO fetches, deterministic template fallback present);
# with a key -> exactly ONE call, all three kinds, both locales, AI text used; basedOn
# references REAL finding ids (computed from the audit, never trusted from the model); a
# garbled/empty/throwing reply degrades to templates and NEVER throws; and drafts.js
# carries NO send/transport token (pure builder behind the provider seam — no fetch()).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [draftsP] = process.argv.slice(1);
    const { generateDrafts, DRAFT_KINDS, DRAFT_LOCALES, normalizeDraftKind } = await import(pathToFileURL(draftsP).href);
    const errs = [];

    const prospect = { id:"acme-dental", name:"Acme Dental Clinic", url:"https://acme.example" };
    const audit = { name:"Acme Dental Clinic", url:"https://acme.example",
      scores:{ seo:40, performance:30, security:20, "best-practices":55, accessibility:60 },
      verdict:{ overall:35, tier:"poor", topFindings:[
        { id:"no-https", priority:"critical", category:"security", title:"Serve the site over HTTPS", recommendation:"Front with Caddy" },
        { id:"response-time-slow", priority:"high", category:"performance", title:"Improve server response time", recommendation:"Cache/CDN" },
        { id:"meta-description-missing", priority:"high", category:"seo", title:"Add a meta description", recommendation:"add one" },
      ] } };
    const realIds = new Set(["no-https","response-time-slow","meta-description-missing"]);

    const shapeOk = (d, label) => {
      if (!DRAFT_KINDS.includes(d.kind)) errs.push(label+": bad kind "+d.kind);
      if (!DRAFT_LOCALES.includes(d.locale)) errs.push(label+": bad locale "+d.locale);
      if (typeof d.body !== "string" || d.body.trim().length < 10) errs.push(label+": empty/short body");
      if (!Array.isArray(d.basedOn)) errs.push(label+": basedOn not an array");
      for (const id of d.basedOn) if (!realIds.has(id)) errs.push(label+": basedOn has a non-real id "+id);
      // content-snippet is a social post -> no subject; outreach/referral carry a subject.
      if (d.kind === "content-snippet" && "subject" in d) errs.push(label+": content-snippet should have no subject");
      if (d.kind !== "content-snippet" && !d.subject) errs.push(label+": "+d.kind+" missing subject");
    };
    const allKindsBothLocales = (drafts, label) => {
      for (const k of DRAFT_KINDS) for (const l of DRAFT_LOCALES)
        if (!drafts.some((d) => d.kind===k && d.locale===l)) errs.push(label+": missing "+k+"/"+l);
    };

    // --- (1) INERT (no key): ZERO fetches, template fallback, full shape ----------
    let calledOff = 0;
    const mockOff = async () => { calledOff++; return { json: async()=>({}) }; };
    const off = await generateDrafts(prospect, audit, {}, { aiFetchImpl: mockOff });
    if (off.enabled !== false) errs.push("off: enabled true");
    if (calledOff !== 0) errs.push("off: made "+calledOff+" fetch(es) — MUST be 0 (no key => no network)");
    if (off.source !== "template") errs.push("off: source not template");
    if (off.drafts.length !== DRAFT_KINDS.length * DRAFT_LOCALES.length) errs.push("off: wrong draft count "+off.drafts.length);
    allKindsBothLocales(off.drafts, "off");
    for (const d of off.drafts) shapeOk(d, "off/"+d.kind+"/"+d.locale);
    // outreach references the 1-2 biggest issues; referral-request is not finding-specific.
    const offOut = off.drafts.find((d)=>d.kind==="outreach"&&d.locale==="ar");
    if (!offOut.basedOn.includes("no-https")) errs.push("off: outreach basedOn missing the top issue");
    const offRef = off.drafts.find((d)=>d.kind==="referral-request"&&d.locale==="en");
    if (offRef.basedOn.length !== 0) errs.push("off: referral basedOn should be empty");

    // --- (2) WITH KEY (mocked): exactly ONE call, AI text used, real basedOn -------
    const aiPayload = {
      outreach:{ ar:{subject:"AR_OUT_SUBJ", body:"نص عربي للتواصل قيمته واضحة"}, en:{subject:"EN_OUT_SUBJ", body:"english outreach body here"} },
      referral:{ ar:{subject:"AR_REF", body:"نص طلب الإحالة"}, en:{subject:"EN_REF", body:"referral request body"} },
      content:{ ar:{body:"منشور تعليمي مفيد"}, en:{body:"educational content post"} },
    };
    let calledOn = 0; let lastInit = null;
    const mockOn = async (_u, init) => { calledOn++; lastInit = init; return { json: async()=>({ choices:[{message:{content: JSON.stringify(aiPayload)}}] }) }; };
    const on = await generateDrafts(prospect, audit, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }, { aiFetchImpl: mockOn });
    if (on.enabled !== true) errs.push("on: enabled false");
    if (calledOn !== 1) errs.push("on: made "+calledOn+" calls (want exactly 1)");
    if (on.source !== "ai") errs.push("on: source not ai");
    allKindsBothLocales(on.drafts, "on");
    for (const d of on.drafts) shapeOk(d, "on/"+d.kind+"/"+d.locale);
    const onOutEn = on.drafts.find((d)=>d.kind==="outreach"&&d.locale==="en");
    if (onOutEn.subject !== "EN_OUT_SUBJ" || onOutEn.body !== "english outreach body here") errs.push("on: AI text not used for outreach/en");
    const onContentAr = on.drafts.find((d)=>d.kind==="content-snippet"&&d.locale==="ar");
    if (onContentAr.body !== "منشور تعليمي مفيد") errs.push("on: AI text not used for content/ar");
    if (!onOutEn.basedOn.includes("no-https")) errs.push("on: basedOn not from the audit (should be real ids)");
    // a request body was actually shaped (the provider seam ran).
    if (!lastInit || !lastInit.body) errs.push("on: no request body shaped");

    // --- (3) GARBLED reply: ONE call, degrade to templates, NO throw --------------
    let calledG = 0;
    const mockGarbled = async () => { calledG++; return { json: async()=>({ choices:[{message:{content:"sorry, not json at all"}}] }) }; };
    const garbled = await generateDrafts(prospect, audit, { AI_PROVIDER:"openai", AI_API_KEY:"sk-y" }, { aiFetchImpl: mockGarbled });
    if (calledG !== 1) errs.push("garbled: calls "+calledG);
    if (garbled.source !== "template") errs.push("garbled: did not degrade to template");
    if (garbled.drafts.length !== DRAFT_KINDS.length * DRAFT_LOCALES.length) errs.push("garbled: wrong draft count");
    allKindsBothLocales(garbled.drafts, "garbled");

    // --- (4) fetch THROWS: best-effort -> templates, error captured, NO throw ------
    let calledT = 0;
    const mockThrow = async () => { calledT++; throw new Error("boom"); };
    const thrown = await generateDrafts(prospect, audit, { AI_PROVIDER:"openai", AI_API_KEY:"sk-z" }, { aiFetchImpl: mockThrow });
    if (calledT !== 1) errs.push("throw: calls "+calledT);
    if (thrown.source !== "template") errs.push("throw: not degraded to template");
    if (!thrown.error || !String(thrown.error).includes("boom")) errs.push("throw: lost the error");
    if (thrown.drafts.length !== DRAFT_KINDS.length * DRAFT_LOCALES.length) errs.push("throw: wrong draft count");

    // --- aliases ----------------------------------------------------------------
    if (normalizeDraftKind("referral") !== "referral-request") errs.push("alias referral wrong");
    if (normalizeDraftKind("content") !== "content-snippet") errs.push("alias content wrong");
    if (normalizeDraftKind("bogus") !== null) errs.push("alias bogus not rejected");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "DRAFTS_OK");
  ' "${ENGINE}/drafts.js")"
  if [[ "${OUT}" == *DRAFTS_OK* ]]; then _pass "drafts: inert (0 fetch, template fallback) without a key; with a key 1 call -> 3 kinds × ar/en, AI text used, basedOn = real finding ids; garbled/throw degrade to templates (never throws)"
  else _fail "drafts wrong — ${OUT}"; fi

  # drafts.js is a PURE builder behind the provider seam: it makes NO direct network call.
  fhasnt "drafts.js makes NO direct fetch call" "${ENGINE}/drafts.js" "fetch("
else
  _skip "drafts (node not available)"
fi

# ===========================================================================
section "ALERT-NOTIFY — rich operator alert (pure, bilingual) + delivery seam (operator-only)"
# ---------------------------------------------------------------------------
# alert.js builds a PURE, deterministic operator heads-up from ONE analysis audit:
# client name, site URL, overall score + tier, the biggest-win line, the top 3 findings,
# the AI lead score ONLY when a prior assist produced one, the saved report path, and an
# explicit operator-only boundary line — in BOTH locales (ar RTL-first default / en).
# notify.js notifyAnalysis then DELIVERS it through the SAME seam as the follow-up
# reminder (PROSPECTS_NOTIFY_CMD / Uptime-Kuma): it writes last-analysis-alert.txt
# always, pipes the full text to the operator's command with a short label as $1, and
# pushes the one-line summary to Kuma — all via INJECTED deps (NO real process/network),
# silent by default, and NEVER to the prospect.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  TMP="$(mktemp -d)"
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync, existsSync } from "node:fs";
    const [alertP, notifyP, badP, goodP, downP, root] = process.argv.slice(1);
    const { formatProspectAlert, formatProspectAlertSummary } = await import(pathToFileURL(alertP).href);
    const { notifyAnalysis } = await import(pathToFileURL(notifyP).href);
    const load = (p) => JSON.parse(readFileSync(p, "utf8"));
    const bad = load(badP), good = load(goodP), down = load(downP);
    const errs = [];
    const has = (s, sub, label) => { if (!s.includes(sub)) errs.push(label + " missing [" + sub + "]"); };
    const hasnt = (s, sub, label) => { if (s.includes(sub)) errs.push(label + " unexpectedly has [" + sub + "]"); };

    // Augment a bad audit with prospect context + a prior AI assist (lead score present).
    const withAi = { ...bad, name: "Acme Dental Clinic", url: "https://acme.example",
      reportFile: "/data/reports/acme-dental-2026-05-25.md",
      aiAssist: { enabled: true, leadScore: 82, nextAction: "prepare-offer" } };

    for (const loc of ["ar", "en"]) {
      const a = formatProspectAlert(withAi, { locale: loc });
      const L = "bad/" + loc;
      if (typeof a !== "string" || a.length < 40) { errs.push(L + ": empty/short"); continue; }
      has(a, "Acme Dental Clinic", L);                         // client name
      has(a, "https://acme.example", L);                        // site URL
      has(a, "35/100", L);                                      // overall score
      has(a, loc === "ar" ? "ضعيف" : "poor", L);                // tier word
      has(a, loc === "ar" ? "النتيجة الإجمالية" : "Overall", L);
      has(a, loc === "ar" ? "أكبر فرصة" : "Biggest win", L);    // opportunity line
      has(a, "Serve the site over HTTPS", L);                   // the top finding title (en, from the engine)
      has(a, loc === "ar" ? "أبرز الملاحظات" : "Top findings", L);
      has(a, "1. 🔴", L);                                        // top-3 list, critical first
      has(a, "82/100", L); has(a, "prepare-offer", L);          // AI lead score + next action
      has(a, loc === "ar" ? "تقييم جودة العميل" : "AI lead score", L);
      has(a, "/data/reports/acme-dental-2026-05-25.md", L);     // saved report path
      // operator-only BOUNDARY, in the right language, and no prospect-send wording.
      has(a, loc === "ar" ? "تذكير للمشغّل فقط" : "Operator-only reminder", L);
      has(a, loc === "ar" ? "لم يُرسَل هذا إلى العميل" : "NOT sent to the prospect", L);
    }

    // RTL-first default: no locale -> Arabic framing; explicit en -> English.
    has(formatProspectAlert(withAi, {}), "تحليل عميل محتمل", "default-locale");
    has(formatProspectAlert(withAi, { locale: "en" }), "Prospect analysis", "en-locale");

    // NO AI assist -> the lead-score line is ABSENT (only shown when present).
    const noAi = formatProspectAlert({ ...good, name: "Good Co", url: "https://good.example" }, { locale: "en" });
    hasnt(noAi, "AI lead score", "good/no-ai");
    has(noAi, "100/100", "good/no-ai"); has(noAi, "excellent", "good/no-ai");
    has(noAi, "No major issues", "good/no-ai");

    // UNREACHABLE -> the urgent line + a single finding; still operator-only.
    const dn = formatProspectAlert({ ...down, name: "Down LLC", url: "https://down.example" }, { locale: "en" });
    has(dn, "unreachable", "down"); has(dn, "0/100", "down"); has(dn, "NOT sent to the prospect", "down");

    // Summary one-liner: compact, single line, carries name + score + lead.
    const sum = formatProspectAlertSummary(withAi, { locale: "en" });
    if (sum.includes("\n")) errs.push("summary not single-line");
    has(sum, "Acme Dental Clinic", "summary"); has(sum, "35/100", "summary"); has(sum, "lead 82", "summary");

    // DETERMINISM: same input -> byte-identical text.
    if (formatProspectAlert(withAi, { locale: "en" }) !== formatProspectAlert(withAi, { locale: "en" })) errs.push("alert not deterministic");

    // --- notifyAnalysis seam (INJECTED deps; NO real process/network) ----------
    const full = formatProspectAlert(withAi, { locale: "en" });
    const summary = formatProspectAlertSummary(withAi, { locale: "en" });

    // (1) zero-config: only the local file is written; no cmd, no kuma.
    let r1 = await notifyAnalysis(root, { full, summary, label: "poor" }, {}, {});
    if (!r1.wrote || !existsSync(r1.wrote)) errs.push("notify: alert file not written");
    if (!readFileSync(r1.wrote, "utf8").includes("Acme Dental Clinic")) errs.push("notify: file content wrong");
    if (r1.cmd !== false || r1.kuma !== false) errs.push("notify: pushed without config");

    // (2) PROSPECTS_NOTIFY_CMD set -> the OPERATOR command gets the FULL text on stdin
    //     and the label as $1 (this is the to-operator delivery; never a prospect).
    let seen = null;
    const spawnImpl = (cmdline, args2, stdin) => { seen = { cmdline, args2, stdin }; return { status: 0 }; };
    const r2 = await notifyAnalysis(root, { full, summary, label: "poor" },
      { PROSPECTS_NOTIFY_CMD: "deliver-to-my-own-telegram" }, { spawnImpl });
    if (r2.cmd !== true) errs.push("notify: cmd not marked sent");
    if (!seen || seen.cmdline !== "deliver-to-my-own-telegram") errs.push("notify: wrong cmd invoked");
    if (!seen || seen.args2[0] !== "poor") errs.push("notify: label not passed as $1");
    if (!seen || !String(seen.stdin).includes("Acme Dental Clinic")) errs.push("notify: full alert not on stdin");
    // BOUNDARY: the delivered payload carries the operator-only line and nothing prospect-addressed.
    if (!String(seen.stdin).includes("NOT sent to the prospect")) errs.push("notify: boundary line missing from payload");

    // (3) Uptime-Kuma set -> one informational push carrying the one-line summary,
    //     time-bounded (an AbortSignal is passed so a hung Kuma cannot block the pipeline).
    let kumaUrl = null; let kumaSignal = false;
    const fetchImpl = async (u, init) => { kumaUrl = String(u); kumaSignal = !!(init && init.signal); return { ok: true }; };
    const r3 = await notifyAnalysis(root, { full, summary, label: "poor" },
      { PROSPECTS_UPTIME_KUMA_PUSH_URL: "https://kuma.example/api/push/abc" }, { fetchImpl });
    if (r3.kuma !== true) errs.push("notify: kuma not marked sent");
    if (!kumaUrl || !kumaUrl.includes("status=up")) errs.push("notify: kuma status not up");
    if (!kumaUrl || !kumaUrl.includes("msg=")) errs.push("notify: kuma msg missing");
    if (!kumaSignal) errs.push("notify: kuma push not time-bounded (no AbortSignal)");

    // (4) a throwing command must NOT break (best-effort; analysis already saved).
    let threw = 0;
    try { await notifyAnalysis(root, { full, summary, label: "x" },
      { PROSPECTS_NOTIFY_CMD: "boom" }, { spawnImpl: () => { throw new Error("nope"); } }); }
    catch { threw = 1; }
    if (threw) errs.push("notify: a throwing cmd was not swallowed");

    console.log(errs.length ? "FAIL: " + errs.join("; ") : "ALERT_OK");
  ' "${ENGINE}/alert.js" "${ENGINE}/notify.js" "${SEOFIX}/audit-bad.json" "${SEOFIX}/audit-good.json" "${SEOFIX}/audit-unreachable.json" "${TMP}")"
  rm -rf "${TMP}"
  if [[ "${OUT}" == *ALERT_OK* ]]; then _pass "alert: bilingual rich operator alert (name/url/score+tier/top3/opportunity/AI-lead/report path/boundary), deterministic; notifyAnalysis delivers via the seam (cmd stdin+label, kuma summary), operator-only, silent-default, best-effort"
  else _fail "alert/notify wrong — ${OUT}"; fi
else
  _skip "alert/notify (node not available)"
fi

# ===========================================================================
section "REAUDIT-ALERT — operator regression heads-up on a meaningful re-audit (pure, bilingual, operator-only)"
# ---------------------------------------------------------------------------
# A re-audit that REGRESSES (a new critical/high finding, a tier drop, or the site
# going offline) builds a concise OPERATOR heads-up via alert.js formatReauditAlert,
# reusing the bilingual diff summary + the SAME operator-only boundary. The gate
# (diff.isMeaningfulChange) decides WHEN to send: an improvement/baseline does NOT
# alert. Pure + deterministic; both locales; carries NO prospect address (operator-only).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [alertP, diffP, goodP, badP, downP] = process.argv.slice(1);
    const { formatReauditAlert, formatReauditAlertSummary } = await import(pathToFileURL(alertP).href);
    const { diffAudits, isMeaningfulChange } = await import(pathToFileURL(diffP).href);
    const load = (p) => JSON.parse(readFileSync(p, "utf8"));
    const good = load(goodP), bad = load(badP), down = load(downP);
    const errs = [];
    const has = (s, sub, l) => { if (!s.includes(sub)) errs.push(l + " missing [" + sub + "]"); };
    const hasnt = (s, sub, l) => { if (s.includes(sub)) errs.push(l + " unexpectedly has [" + sub + "]"); };

    // REGRESSION (good -> bad): meaningful => alert-worthy in both locales.
    const reg = diffAudits(good, bad);
    if (!isMeaningfulChange(reg)) errs.push("regression not meaningful");
    const aud = { name: "Acme Dental", url: "https://acme.example", engine: "probe", reportFile: "data/seo/reports/acme.md", diff: reg };
    const en = formatReauditAlert(aud, { locale: "en" });
    const ar = formatReauditAlert(aud, { locale: "ar" });
    // English: leads with the client + a regression reason; carries the change summary + boundary.
    has(en, "Acme Dental", "en"); has(en, "regressed", "en");
    has(en, "new critical", "en");                       // the lead reason
    has(en, "Changes since last audit", "en");
    has(en, "NOT sent to the prospect", "en");           // operator-only boundary
    has(en, "⚠️", "en");
    // Arabic: localized framing + the AR operator-only boundary.
    has(ar, "تراجُع", "ar");
    has(ar, "التغييرات منذ آخر فحص", "ar");
    has(ar, "لم يُرسَل هذا إلى العميل", "ar");
    // OPERATOR-ONLY: there is no recipient/address field — only the site URL is present.
    for (const s of [en, ar]) { hasnt(s, "To:", "no-recipient"); hasnt(s, "@", "no-handle"); }

    // OUTAGE (good -> down): the lead reason is the offline regression.
    const outAlert = formatReauditAlert({ name: "Acme", diff: diffAudits(good, down) }, { locale: "en" });
    has(outAlert, "offline", "outage");

    // Compact summary line, both locales.
    has(formatReauditAlertSummary(aud, { locale: "en" }), "regressed", "sum-en");
    has(formatReauditAlertSummary(aud, { locale: "ar" }), "تراجُع", "sum-ar");

    // GATE: an IMPROVEMENT (bad -> good) and a BASELINE are NOT alert-worthy.
    if (isMeaningfulChange(diffAudits(bad, good))) errs.push("improvement wrongly alert-worthy");
    if (isMeaningfulChange(diffAudits(null, good))) errs.push("baseline wrongly alert-worthy");

    // DETERMINISM.
    if (formatReauditAlert(aud, { locale: "en" }) !== en) errs.push("formatReauditAlert not deterministic");

    console.log(errs.length ? "FAIL: " + errs.join("; ") : "REAUDIT_ALERT_OK");
  ' "${ENGINE}/alert.js" "${SEOENGINE}/diff.js" "${SEOFIX}/audit-good.json" "${SEOFIX}/audit-bad.json" "${SEOFIX}/audit-unreachable.json")"
  if [[ "${OUT}" == *REAUDIT_ALERT_OK* ]]; then _pass "reaudit-alert: bilingual operator regression heads-up (reason + change summary + boundary); gated by isMeaningfulChange; operator-only; deterministic"
  else _fail "reaudit-alert wrong — ${OUT}"; fi
else
  _skip "reaudit-alert (node not available)"
fi

# ===========================================================================
section "FULL-PIPELINE — analyze --notify runs every step IN ORDER via mocked seams; no send/scrape"
# ---------------------------------------------------------------------------
# run-analysis.js is the PURE orchestrator behind `prospects.sh analyze <id> --notify`.
# It sequences the full automated flow — SSRF-guarded full audit (all 5 categories) ->
# verdict -> optional AI enrichment -> Markdown (+ optional PDF) report saved -> rich
# OPERATOR alert -> follow-up reminder set — through INJECTED seams (NO real network /
# disk / AI / process). This case proves: (a) the phases run in the documented order and
# (b) every seam is invoked in that order; (c) the audit's five categories + the verdict
# thread into the saved record; (d) the env (with the AI key) reaches the analyze seam so
# AI enrichment is wired; (e) Markdown AND the optional PDF/HTML are saved; (f) the alert
# is OPERATOR-ONLY (boundary line; channel push only with --notify); (g) the follow-up is
# set to today+N on --notify; (h) WITHOUT --notify the PDF, the channel push and the
# follow-up are gated off; (i) the ONLY outbound seam is the operator alert — there is NO
# send-to-prospect or scrape path (its payload is {full,summary,label}, no recipient).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [runP] = process.argv.slice(1);
    const { runAnalysisPipeline, PIPELINE_PHASES, followupDate } = await import(pathToFileURL(runP).href);
    const errs = [];

    const prospect = { id:"acme-dental", name:"Acme Dental Clinic", url:"https://acme.example",
      status:"contacted", followup:null, notes:[] };

    // A realistic analyze RESULT (the reused SEO engine output): ALL FIVE category
    // scores + a pre-attached verdict + the (off) AI flag + counts + markdown.
    const audit = { engine:"probe", url:"https://acme.example", ok:true,
      scores:{ seo:21, performance:40, security:30, "best-practices":55, accessibility:60 },
      verdict:{ overall:35, tier:"poor",
        topFindings:[
          { priority:"critical", category:"security", title:"Serve the site over HTTPS" },
          { priority:"high", category:"seo", title:"Add a meta description" },
          { priority:"medium", category:"performance", title:"Compress images" },
        ],
        opportunity:"Biggest win: Serve the site over HTTPS." } };
    const analyzeResult = { audit, report:"# SEO & site-quality report\nbody", summary:"weak site",
      counts:{ critical:1, high:1, medium:1, low:0 }, ai:{ enabled:false } };

    // Spy factory: records the REAL call order across ALL seams (no real I/O anywhere).
    let order=[]; let analyzeEnv=null; let analyzeDeps=null; let savedMd=null;
    let lastRec=null; let deliveredAlert=null; let deliveredPush=null;
    const mk = () => {
      order=[]; analyzeEnv=null; analyzeDeps=null; savedMd=null; lastRec=null;
      deliveredAlert=null; deliveredPush=null;
      let pdfCalled=0; let artCalled=0;
      return {
        seams: {
          analyze: async (p, env, d) => { order.push("analyze"); analyzeEnv=env; analyzeDeps=d; return analyzeResult; },
          saveReport: (id, ts, md) => { order.push("saveReport"); savedMd=md; return "/data/reports/"+id+"-"+ts+".md"; },
          renderPdf: async (md, o) => { order.push("renderPdf"); pdfCalled++; return { html:"<html>"+o.lang+"</html>", pdf: Buffer.from("%PDF-1.4"), degraded:false, reason:"" }; },
          saveArtifact: (id, ts, ext) => { order.push("saveArtifact:"+ext); artCalled++; return "/data/reports/"+id+"-"+ts+"."+ext; },
          saveRecord: (rec) => { order.push("saveRecord"); lastRec=rec; },
          deliverAlert: async (alert, push) => { order.push("deliverAlert"); deliveredAlert=alert; deliveredPush=push; return { wrote:"/data/last-analysis-alert.txt", cmd:push, kuma:false, label:alert.label }; },
          now: () => Date.parse("2026-05-25T08:00:00Z"),
        },
        counts: () => ({ pdfCalled, artCalled }),
      };
    };

    // ===== (1) FULL run: --notify + --pdf -> every phase, IN ORDER ===============
    let h = mk();
    const full = await runAnalysisPipeline(prospect, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" },
      { engine:"probe", locale:"en", notify:true, pdf:true, followupDays:3, today:"2026-05-25" }, h.seams);

    if (JSON.stringify(full.steps) !== JSON.stringify(["audit","report","pdf","record","alert","followup"]))
      errs.push("phase order wrong: "+JSON.stringify(full.steps));
    const wantOrder = ["analyze","saveReport","renderPdf","saveArtifact:html","saveArtifact:pdf","saveRecord","deliverAlert","saveRecord"];
    if (JSON.stringify(order) !== JSON.stringify(wantOrder))
      errs.push("seam order wrong: "+JSON.stringify(order));
    const idx = (s) => order.indexOf(s);
    if (!(idx("analyze") < idx("saveReport") && idx("saveReport") < idx("deliverAlert"))) errs.push("audit/report/alert not ordered");
    if (!(order.lastIndexOf("saveRecord") > idx("deliverAlert"))) errs.push("follow-up persist not after the alert");

    const sc = (lastRec && lastRec.lastAnalysis && lastRec.lastAnalysis.scores) || {};
    for (const cat of ["seo","performance","security","best-practices","accessibility"])
      if (typeof sc[cat] !== "number") errs.push("category missing from record: "+cat);
    if (!lastRec.lastAnalysis.verdict || lastRec.lastAnalysis.verdict.tier !== "poor") errs.push("verdict not recorded");

    if (!analyzeEnv || analyzeEnv.AI_PROVIDER !== "openai" || analyzeEnv.AI_API_KEY !== "sk-x") errs.push("AI env not passed to the analyze seam");
    if (!analyzeDeps || analyzeDeps.engine !== "probe") errs.push("engine not passed to the analyze seam");

    if (savedMd !== analyzeResult.report) errs.push("saved markdown != report");
    if (!String(full.reportFile).endsWith(".md")) errs.push("reportFile not .md");
    if (!String(full.htmlFile).endsWith(".html")) errs.push("htmlFile not .html");
    if (!String(full.pdfFile).endsWith(".pdf")) errs.push("pdfFile not .pdf");

    if (deliveredPush !== true) errs.push("alert not pushed to the channel on --notify");
    if (!deliveredAlert || !deliveredAlert.full.includes("NOT sent to the prospect")) errs.push("alert missing the operator-only boundary");
    if (!deliveredAlert.full.includes("Acme Dental Clinic")) errs.push("alert missing the client name");
    if (!deliveredAlert.full.includes("35/100")) errs.push("alert missing the overall score");
    if (!deliveredAlert.full.includes("/data/reports/")) errs.push("alert missing the report path");
    if (deliveredAlert.summary.includes("\n")) errs.push("alert summary not single-line");
    if (deliveredAlert.label !== "poor") errs.push("alert label not the tier");

    if (full.followup !== "2026-05-28") errs.push("followup date wrong: "+full.followup);
    if (lastRec.followup !== "2026-05-28") errs.push("followup not set on the record: "+lastRec.followup);

    // ===== (2) MINIMAL run: no --notify, no --pdf -> phases GATED ================
    h = mk();
    const min = await runAnalysisPipeline(prospect, {},
      { engine:"probe", locale:"en", notify:false, pdf:false }, h.seams);
    if (JSON.stringify(min.steps) !== JSON.stringify(["audit","report","record","alert"]))
      errs.push("minimal phase order wrong: "+JSON.stringify(min.steps));
    if (h.counts().pdfCalled !== 0 || h.counts().artCalled !== 0) errs.push("pdf seams called without --pdf");
    if (deliveredPush !== false) errs.push("channel push not gated without --notify");
    if (min.followup !== null) errs.push("follow-up set without --notify");

    // ===== (3) NO send/scrape: the ONLY outbound seam is the operator alert ======
    // Its payload is exactly {full,summary,label} — an operator heads-up with NO
    // recipient/address field. There is no prospect-send and no scraper anywhere here.
    const keys = Object.keys(deliveredAlert).sort().join(",");
    if (keys !== "full,label,summary") errs.push("alert payload has unexpected fields: "+keys);

    // ===== (4) followupDate is pure + correct (incl. year roll-over) =============
    if (followupDate("2026-05-25", 3) !== "2026-05-28") errs.push("followupDate +3 wrong");
    if (followupDate("2026-12-31", 1) !== "2027-01-01") errs.push("followupDate year roll wrong");
    if (followupDate("2026-05-25", 0) !== "2026-05-25") errs.push("followupDate +0 wrong");

    // ===== (5) a missing required seam throws clearly (fail-safe orchestration) ==
    let threw=0; try { await runAnalysisPipeline(prospect, {}, {}, { analyze: async()=>analyzeResult }); } catch { threw++; }
    if (!threw) errs.push("a missing required seam did not throw");

    if (JSON.stringify(PIPELINE_PHASES) !== JSON.stringify(["audit","report","pdf","record","alert","followup"]))
      errs.push("PIPELINE_PHASES drifted: "+JSON.stringify(PIPELINE_PHASES));

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "PIPELINE_OK");
  ' "${ENGINE}/run-analysis.js")"
  if [[ "${OUT}" == *PIPELINE_OK* ]]; then _pass "full pipeline: audit->report->[pdf]->record->alert->[followup] IN ORDER via mocked seams; 5 categories+verdict recorded; AI env wired; md+pdf saved; operator-only alert (push gated by --notify); follow-up = today+N (gated); no send/scrape path"
  else _fail "full pipeline wrong — ${OUT}"; fi
else
  _skip "full pipeline (node not available)"
fi

# ===========================================================================
section "REAUDIT-PIPELINE — re-analyze diffs vs previous + alerts ONLY on regression (opt-in, additive)"
# ---------------------------------------------------------------------------
# When the caller injects deps.readPrevious(id) (the prior stored audit), the pipeline
# diffs the new audit against it, attaches audit.diff, and — ONLY on a MEANINGFUL
# regression (new critical/high, tier drop, or offline) — pushes a SECOND operator
# heads-up (label 'regression') through the SAME deliverAlert seam. It is strictly
# ADDITIVE: with no readPrevious (the default) nothing changes and result.diff is null.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [runP] = process.argv.slice(1);
    const { runAnalysisPipeline } = await import(pathToFileURL(runP).href);
    const errs = [];
    const prospect = { id:"acme-dental", name:"Acme Dental Clinic", url:"https://acme.example", status:"contacted", followup:null, notes:[] };

    // The CURRENT audit is weak (poor/critical). A strong PREVIOUS audit => regression.
    const audit = { engine:"probe", url:"https://acme.example", ok:true,
      scores:{ seo:21, performance:40, security:30, "best-practices":55, accessibility:60 },
      verdict:{ overall:35, tier:"poor", topFindings:[{ id:"no-https", priority:"critical", category:"security", title:"Serve the site over HTTPS" }], opportunity:"x" },
      findings:[{ id:"no-https", priority:"critical", category:"security", title:"Serve the site over HTTPS" }] };
    const analyzeResult = { audit, report:"# r", summary:"weak", counts:{ critical:1, high:0, medium:0, low:0 }, ai:{ enabled:false } };
    const strongPrev = { ok:true, scores:{ seo:100, performance:100, security:100, "best-practices":100, accessibility:100 }, verdict:{ overall:100, tier:"excellent" }, findings:[] };

    const mkSeams = (readPrevious) => {
      const delivered = [];
      const seams = {
        analyze: async () => analyzeResult,
        saveReport: () => "/data/r.md",
        saveRecord: () => {},
        deliverAlert: async (alert, push) => { delivered.push(alert.label); return { label: alert.label, cmd: push }; },
        now: () => Date.parse("2026-05-25T08:00:00Z"),
      };
      if (readPrevious) seams.readPrevious = readPrevious;
      return { seams, delivered };
    };

    // (1) REGRESSION: previous strong, current weak => a SECOND alert (label regression).
    let h = mkSeams(async () => strongPrev);
    let r = await runAnalysisPipeline(prospect, {}, { locale:"en", notify:true }, h.seams);
    if (!r.steps.includes("reaudit")) errs.push("regression: no reaudit step");
    if (!h.delivered.includes("regression")) errs.push("regression: no regression alert delivered");
    if (!r.diff || r.diff.baseline) errs.push("regression: diff not attached");
    if (!r.audit.diff) errs.push("regression: audit.diff not attached");

    // (2) IMPROVEMENT: previous weak, current strong => NO regression alert (gated off).
    const weakPrev = { ok:true, scores:{ seo:21, performance:40, security:30, "best-practices":55, accessibility:60 }, verdict:{ overall:35, tier:"poor" }, findings:[{ id:"no-https", priority:"critical", category:"security", title:"Serve the site over HTTPS" }] };
    // make the CURRENT audit strong for this case
    const strongAudit = { ...audit, scores:{ seo:100, performance:100, security:100, "best-practices":100, accessibility:100 }, verdict:{ overall:100, tier:"excellent" }, findings:[] };
    const improveSeams = mkSeams(async () => weakPrev);
    improveSeams.seams.analyze = async () => ({ audit: strongAudit, report:"# r", summary:"strong", counts:{critical:0,high:0,medium:0,low:0}, ai:{enabled:false} });
    let r2 = await runAnalysisPipeline(prospect, {}, { locale:"en", notify:true }, improveSeams.seams);
    if (r2.steps.includes("reaudit")) errs.push("improvement wrongly added reaudit step");
    if (improveSeams.delivered.filter(l=>l==="regression").length) errs.push("improvement wrongly alerted regression");

    // (3) ADDITIVE: with NO readPrevious, behaviour is unchanged + result.diff is null.
    let h3 = mkSeams(null);
    let r3 = await runAnalysisPipeline(prospect, {}, { locale:"en", notify:true }, h3.seams);
    if (r3.steps.includes("reaudit")) errs.push("no-readPrevious added a reaudit step");
    if (r3.diff !== null) errs.push("no-readPrevious diff not null");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "REAUDIT_PIPE_OK");
  ' "${ENGINE}/run-analysis.js")"
  if [[ "${OUT}" == *REAUDIT_PIPE_OK* ]]; then _pass "reaudit-pipeline: diffs vs previous (readPrevious dep), alerts ONLY on regression via the same seam; additive (inert without readPrevious)"
  else _fail "reaudit-pipeline wrong — ${OUT}"; fi
else
  _skip "reaudit-pipeline (node not available)"
fi

# ===========================================================================
section "PANEL-PIPELINE — --panel attaches the specialist panel + #1 risk in the alert (opt-in, additive)"
# ---------------------------------------------------------------------------
# When opts.panel + deps.runPanel are provided, the pipeline attaches the panel bundle to
# the audit, appends the panel SECTION to the report (before save), and the operator alert
# surfaces the single #1 cross-cutting priority. Strictly ADDITIVE: with panel OFF nothing
# changes and result.panel is null. Reuses the SEO specialists engine (operator-only).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [runP, spP, alertP] = process.argv.slice(1);
    const { runAnalysisPipeline } = await import(pathToFileURL(runP).href);
    const { runSpecialistPanel } = await import(pathToFileURL(spP).href);
    const { formatProspectAlert } = await import(pathToFileURL(alertP).href);
    const errs = [];
    const prospect = { id:"acme-dental", name:"Acme Dental Clinic", url:"https://acme.example", status:"contacted", followup:null, notes:[] };
    const audit = { engine:"probe", url:"https://acme.example", ok:true,
      scores:{ seo:21, performance:40, security:30, "best-practices":55, accessibility:60 },
      verdict:{ overall:35, tier:"poor", topFindings:[{ id:"no-https", priority:"critical", category:"security", title:"Serve the site over HTTPS" }] },
      findings:[{ id:"no-https", priority:"critical", category:"security", title:"Serve the site over HTTPS", recommendation:"Front with Caddy" }] };
    const analyzeResult = { audit, report:"# base report", summary:"weak", counts:{ critical:1, high:0, medium:0, low:0 }, ai:{ enabled:false } };

    const mk = (withPanel) => {
      const delivered = [];
      const seams = {
        analyze: async () => ({ ...analyzeResult, audit: { ...audit } }),
        saveReport: (id, ts, md) => { seams._savedMd = md; return "/data/r.md"; },
        saveRecord: () => {},
        deliverAlert: async (alert) => { delivered.push(alert); return { label: alert.label }; },
        now: () => Date.parse("2026-05-25T08:00:00Z"),
      };
      if (withPanel) seams.runPanel = async (a) => runSpecialistPanel(a, {}, {}); // inert -> templates
      return { seams, delivered };
    };

    // (1) PANEL ON: bundle attached, section in the saved report, #1 line in the alert.
    let h = mk(true);
    let r = await runAnalysisPipeline(prospect, {}, { locale:"en", notify:true, panel:true }, h.seams);
    if (!r.steps.includes("panel")) errs.push("no panel step");
    if (!r.panel || !r.panel.panel || !r.panel.panel.topPriority) errs.push("panel not returned");
    if (!r.audit.panel) errs.push("panel not attached to audit");
    if (!h.seams._savedMd.includes("Specialist panel")) errs.push("saved report missing panel section");
    if (!r.report.includes("Specialist panel")) errs.push("result.report missing panel section");
    // the delivered alert carries the #1 cross-cutting priority line.
    const full = (h.delivered[0] && h.delivered[0].full) || "";
    if (!/#1 priority/i.test(full)) errs.push("alert missing #1 priority line");

    // (2) PANEL OFF (default): no panel step, result.panel null, report unchanged.
    let h2 = mk(false);
    let r2 = await runAnalysisPipeline(prospect, {}, { locale:"en", notify:true }, h2.seams);
    if (r2.steps.includes("panel")) errs.push("panel step ran with panel off");
    if (r2.panel !== null) errs.push("result.panel not null with panel off");
    if (h2.seams._savedMd.includes("Specialist panel")) errs.push("report has panel section with panel off");

    // (3) the alert builder adds the #1 line ONLY when audit.panel is present.
    const bundle = await runSpecialistPanel(audit, {}, {});
    const withPanel = formatProspectAlert({ ...audit, name:"Acme", panel: bundle }, { locale:"en" });
    const without = formatProspectAlert({ ...audit, name:"Acme" }, { locale:"en" });
    if (!/#1 priority/i.test(withPanel)) errs.push("formatProspectAlert: no #1 line with panel");
    if (/#1 priority/i.test(without)) errs.push("formatProspectAlert: #1 line leaked without panel");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "PANEL_PIPE_OK");
  ' "${ENGINE}/run-analysis.js" "${SEOENGINE}/specialists.js" "${ENGINE}/alert.js")"
  if [[ "${OUT}" == *PANEL_PIPE_OK* ]]; then _pass "panel-pipeline: --panel attaches the bundle, appends the report section, alert shows #1; additive (off => unchanged, result.panel null)"
  else _fail "panel-pipeline wrong — ${OUT}"; fi
else
  _skip "panel-pipeline (node not available)"
fi
# Wiring: prospects binds the panel seam; helper forwards --panel; alert shows the #1 line.
fhas  "prospects.js imports the specialists panel" "${ENGINE}/prospects.js" "runSpecialistPanel"
fhas  "prospects.js binds the runPanel seam"      "${ENGINE}/prospects.js" "runPanel:"
fhas  "prospects.js passes panel: wantPanel"      "${ENGINE}/prospects.js" "panel: wantPanel"
fhas  "run-analysis imports renderPanelSection"   "${ENGINE}/run-analysis.js" "renderPanelSection"
fhas  "alert.js imports panelTopRiskLine"         "${ENGINE}/alert.js" "panelTopRiskLine"
fhas  "prospects.sh has a --panel flag"           "${HELPER}" "--panel)"
fhas  "prospects.sh forwards --panel on analyze"  "${HELPER}" 'ARGS+=(--panel)'

# ===========================================================================
section "DEPTH-PIPELINE — --depth maps to the right seams (quick=0 / standard=1 / deep=panel)"
# ---------------------------------------------------------------------------
# The same cost-vs-depth dial that scripts/seo.sh exposes is honoured by
# run-analysis.js: opts.depth is threaded to the analyze seam (quick skips
# the AI enrichment entirely, standard runs it, deep adds the panel section)
# and pinned on the result + the audit so the report header reflects the
# level. Legacy opts.panel = deep (back-compat). Drives the SAME pipeline
# the CLI uses, with mocked seams (NO network, NO Docker, NO AI key needed
# — all three levels degrade to deterministic templates without a key).
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [runP, depthP, analyzeP, spP, badP] = process.argv.slice(1);
    const { runAnalysisPipeline } = await import(pathToFileURL(runP).href);
    const { capabilitiesFor } = await import(pathToFileURL(depthP).href);
    const { reportFromAudit } = await import(pathToFileURL(analyzeP).href);
    const { runSpecialistPanel } = await import(pathToFileURL(spP).href);
    const audit = JSON.parse(readFileSync(badP, "utf8"));
    const prospect = { id:"acme-dental", name:"Acme Dental Clinic", url:"https://acme.example", status:"contacted", followup:null, notes:[] };
    const errs = [];

    const mkSeams = (depthFromAnalyze) => {
      let analyzeDepth = null;
      const seams = {
        analyze: async (p, env, d) => {
          analyzeDepth = d.depth || null;
          // Faithfully reuse the SEO engine so the AI-fetch count truly reflects depth.
          // No key set => enrich is inert (0 fetches at every level inside enrich), but
          // capabilitiesFor still gates whether enrich runs at all (quick = no call).
          return reportFromAudit({ ...audit }, env, { depth: d.depth });
        },
        saveReport: (id, ts, md) => { seams._savedMd = md; return "/data/r.md"; },
        saveRecord: () => {},
        deliverAlert: async (a) => ({ label: a.label }),
        runPanel: async (a) => runSpecialistPanel(a, {}, {}), // inert -> templates (0 fetch)
        now: () => Date.parse("2026-05-25T08:00:00Z"),
        get analyzeDepth() { return analyzeDepth; },
      };
      return seams;
    };

    // (1) explicit quick: depth threaded to analyze; result.depth=quick; no panel;
    //     no AI block in the saved report header line.
    const s1 = mkSeams();
    const r1 = await runAnalysisPipeline(prospect, {}, { locale:"en", depth:"quick" }, s1);
    if (r1.depth !== "quick") errs.push("quick: result.depth wrong: "+r1.depth);
    if (s1.analyzeDepth !== "quick") errs.push("quick: analyze did not receive depth=quick (got "+s1.analyzeDepth+")");
    if (r1.steps.includes("panel")) errs.push("quick wrongly invoked the panel step");
    if (!/Depth:.*quick/i.test(s1._savedMd)) errs.push("quick: saved report missing depth header");
    if (/Specialist panel/.test(s1._savedMd)) errs.push("quick: saved report has panel section");
    // Quick depth never invokes the AI enrichment, so the report carries the OFF block.
    if (!/AI enrichment is OFF|الذكاء الاصطناعي/.test(s1._savedMd)) errs.push("quick: missing AI-off marker (enrichment block not skipped)");

    // (2) explicit standard: depth threaded; no panel step; header pins standard.
    const s2 = mkSeams();
    const r2 = await runAnalysisPipeline(prospect, {}, { locale:"en", depth:"standard" }, s2);
    if (r2.depth !== "standard") errs.push("standard: result.depth wrong: "+r2.depth);
    if (s2.analyzeDepth !== "standard") errs.push("standard: analyze did not receive depth=standard");
    if (r2.steps.includes("panel")) errs.push("standard wrongly invoked the panel step");
    if (!/Depth:.*standard/i.test(s2._savedMd)) errs.push("standard: header missing depth marker");

    // (3) explicit deep: panel step runs; panel section in the saved report; header pins deep.
    const s3 = mkSeams();
    const r3 = await runAnalysisPipeline(prospect, {}, { locale:"en", depth:"deep" }, s3);
    if (r3.depth !== "deep") errs.push("deep: result.depth wrong: "+r3.depth);
    if (s3.analyzeDepth !== "deep") errs.push("deep: analyze did not receive depth=deep");
    if (!r3.steps.includes("panel")) errs.push("deep did NOT invoke the panel step");
    if (!s3._savedMd.includes("Specialist panel")) errs.push("deep: saved report missing panel section");
    if (!/Depth:.*deep/i.test(s3._savedMd)) errs.push("deep: header missing depth marker");

    // (4) legacy opts.panel = deep (back-compat).
    const s4 = mkSeams();
    const r4 = await runAnalysisPipeline(prospect, {}, { locale:"en", panel:true }, s4);
    if (r4.depth !== "deep") errs.push("--panel back-compat: result.depth not deep (got "+r4.depth+")");
    if (!r4.steps.includes("panel")) errs.push("--panel back-compat: no panel step");

    // (5) unknown depth: REJECTED with a clear message; pipeline throws BEFORE analyze runs.
    let threw = "";
    try { await runAnalysisPipeline(prospect, {}, { locale:"en", depth:"fast" }, mkSeams()); }
    catch (e) { threw = String(e.message || e); }
    if (!threw) errs.push("unknown depth: pipeline did not throw");
    if (threw && !/unknown analysis depth/i.test(threw)) errs.push("unknown depth: wrong message: "+threw);

    // (6) NO --depth + no env: defaults to quick (no AI key set in this run).
    const s6 = mkSeams();
    const r6 = await runAnalysisPipeline(prospect, {}, { locale:"en" }, s6);
    if (r6.depth !== "quick") errs.push("default (no env): result.depth not quick (got "+r6.depth+")");
    if (r6.steps.includes("panel")) errs.push("default invoked the panel step");

    // (7) NO --depth + key set in env: defaults to standard.
    const s7 = mkSeams();
    const r7 = await runAnalysisPipeline(prospect, { AI_PROVIDER:"openai", AI_API_KEY:"sk-x" }, { locale:"en" }, s7);
    if (r7.depth !== "standard") errs.push("default (key set): result.depth not standard (got "+r7.depth+")");

    // (8) capabilities sanity (the same module the pipeline uses).
    const c = capabilitiesFor("standard");
    if (c.ai !== true || c.panel !== false) errs.push("capabilitiesFor wrong: "+JSON.stringify(c));

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "DEPTH_PIPE_OK");
  ' "${ENGINE}/run-analysis.js" "${SEOENGINE}/depth.js" "${ENGINE}/analyze.js" "${SEOENGINE}/specialists.js" "${SEOFIX}/audit-bad.json")"
  if [[ "${OUT}" == *DEPTH_PIPE_OK* ]]; then _pass "depth-pipeline: quick / standard / deep map to right seams; --panel back-compat; unknown rejected; key-presence default; header pins level"
  else _fail "depth-pipeline wrong — ${OUT}"; fi
else
  _skip "depth-pipeline (node not available)"
fi
# Wiring: helper exposes --depth + validates; engine threads it through.
fhas  "prospects-lib defines PROSPECTS_DEPTHS"    "${LIB}" "PROSPECTS_DEPTHS="
fhas  "prospects-lib has prospects_valid_depth"   "${LIB}" "prospects_valid_depth()"
fhas  "prospects.sh has a --depth flag"           "${HELPER}" "--depth)"
fhas  "prospects.sh validates --depth before docker" "${HELPER}" "prospects_valid_depth"
fhas  "prospects.sh forwards --depth on analyze"  "${HELPER}" 'ARGS+=(--depth "${F_DEPTH}")'
fhas  "prospects.js threads --depth into pipeline" "${ENGINE}/prospects.js" "depth: depthArg"
fhas  "run-analysis.js imports the depth resolver" "${ENGINE}/run-analysis.js" "from '../../seo/engine/depth.js'"
fhas  "analyze.js imports the depth capabilities" "${ENGINE}/analyze.js" "from '../../seo/engine/depth.js'"
ok    "prospects.sh rejects an unknown --depth"   bash -c '! "'"${HELPER}"'" analyze acme-dental --depth=fast >/dev/null 2>&1'
ok    "prospects-lib: valid depths"               bash -c '. "'"${LIB}"'"; prospects_valid_depth quick && prospects_valid_depth standard && prospects_valid_depth deep'
no    "prospects-lib: rejects an unknown depth"   bash -c '. "'"${LIB}"'"; prospects_valid_depth fast'

# ===========================================================================
section "COMPETITORS-PIPELINE — --competitor threaded through analyze + saved-report section + bounded"
# ---------------------------------------------------------------------------
# The pipeline accepts opts.competitorUrls (the helper forwards --competitor).
# The analyze seam receives them and audit.competitors is set on the result;
# the saved report gains an additive "Competitor comparison" section. Bound is
# enforced (defence in depth — the helper script also checks). A blocked/failed
# competitor is RECORDED, never fatal. Strictly additive: with no competitors,
# audit.competitors stays unset and the section is absent.
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    import { readFileSync } from "node:fs";
    const [runP, compP, analyzeP, badP, goodP] = process.argv.slice(1);
    const { runAnalysisPipeline } = await import(pathToFileURL(runP).href);
    const { compareSites, MAX_COMPETITORS } = await import(pathToFileURL(compP).href);
    const { reportFromAudit } = await import(pathToFileURL(analyzeP).href);
    const bad  = JSON.parse(readFileSync(badP, "utf8"));
    const good = JSON.parse(readFileSync(goodP, "utf8"));
    const prospect = { id:"acme-dental", name:"Acme Dental Clinic", url:"https://acme.example", status:"contacted", followup:null, notes:[] };
    const errs = [];

    // Mock the analyze seam: when competitorUrls are passed, it pre-computes a
    // comparison against fixture competitor audits — the same shape compareSites
    // would build. (The real analyzeProspect calls probeCompetitors; we drive a
    // FIXTURE-based variant offline.)
    const mkSeams = (competitorAudits) => {
      let receivedCompetitorUrls = null;
      const seams = {
        analyze: async (p, env, d) => {
          receivedCompetitorUrls = d.competitorUrls || null;
          const audit = { ...bad };
          if (Array.isArray(d.competitorUrls) && d.competitorUrls.length) {
            audit.competitors = compareSites(audit, competitorAudits || []);
          }
          const r = await reportFromAudit(audit, env, { depth: d.depth });
          return r;
        },
        saveReport: (id, ts, md) => { seams._savedMd = md; return "/data/r.md"; },
        saveRecord: () => {},
        deliverAlert: async (a) => ({ label: a.label }),
        now: () => Date.parse("2026-05-25T08:00:00Z"),
        get receivedCompetitorUrls() { return receivedCompetitorUrls; },
      };
      return seams;
    };

    // (1) WITH competitors: the analyze seam gets the URLs, audit.competitors is set,
    //     the saved report includes the section, and result.competitors mirrors it.
    const s1 = mkSeams([good, { ...bad, name:"blocked", url:"http://10.0.0.1/", ok:false, status:"blocked by SSRF guard: refusing private/reserved IPv4 address (10.0.0.1)" }]);
    const r1 = await runAnalysisPipeline(prospect, {}, { locale:"en", depth:"quick", competitorUrls:["https://comp1.example", "http://10.0.0.1/"] }, s1);
    if (!Array.isArray(s1.receivedCompetitorUrls) || s1.receivedCompetitorUrls.length !== 2) errs.push("competitorUrls not forwarded to analyze");
    if (!r1.audit.competitors) errs.push("audit.competitors not set");
    if (!r1.competitors) errs.push("result.competitors not set");
    if (!r1.steps.includes("competitors")) errs.push("competitors step missing");
    if (!/## Competitor comparison/.test(s1._savedMd)) errs.push("saved report missing competitor section");
    if (!/not audited/i.test(s1._savedMd)) errs.push("blocked competitor not surfaced");

    // (2) NO competitors: additive — audit.competitors stays unset; no section.
    const s2 = mkSeams();
    const r2 = await runAnalysisPipeline(prospect, {}, { locale:"en", depth:"quick" }, s2);
    if (r2.audit.competitors) errs.push("audit.competitors set without urls");
    if (r2.competitors !== null) errs.push("result.competitors not null without urls");
    if (r2.steps.includes("competitors")) errs.push("competitors step ran without urls");
    if (/## Competitor comparison/.test(s2._savedMd)) errs.push("section appeared without urls");

    // (3) OVER-BOUND: the pipeline throws BEFORE the analyze seam runs.
    let analyzeRan = false; const s3 = mkSeams();
    s3.analyze = async () => { analyzeRan = true; return { audit:{...bad}, report:"x", summary:"x", counts:{}, ai:{} }; };
    let threw = "";
    try { await runAnalysisPipeline(prospect, {}, { locale:"en", competitorUrls: new Array(MAX_COMPETITORS + 1).fill("https://x") }, s3); }
    catch (e) { threw = String(e.message || e); }
    if (!/too many competitor/i.test(threw)) errs.push("over-bound not refused: "+threw);
    if (analyzeRan) errs.push("analyze ran despite over-bound");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "COMPETITORS_PIPE_OK");
  ' "${ENGINE}/run-analysis.js" "${SEOENGINE}/competitors.js" "${ENGINE}/analyze.js" "${SEOFIX}/audit-bad.json" "${SEOFIX}/audit-good.json")"
  if [[ "${OUT}" == *COMPETITORS_PIPE_OK* ]]; then _pass "competitors-pipeline: --competitor forwarded; audit.competitors set; report gains the section; bounded; blocked competitor surfaced; additive"
  else _fail "competitors-pipeline wrong — ${OUT}"; fi
else
  _skip "competitors-pipeline (node not available)"
fi
# Wiring: prospects helper accepts --competitor + bounded validation; engine threads it through.
fhas  "prospects-lib defines PROSPECTS_MAX_COMPETITORS=3"  "${LIB}" "PROSPECTS_MAX_COMPETITORS=3"
fhas  "prospects.sh accepts --competitor (repeatable)"    "${HELPER}" "--competitor)"
fhas  "prospects.sh validates --competitor before docker" "${HELPER}" "Too many --competitor"
fhas  "prospects.sh forwards --competitor on analyze"    "${HELPER}" 'ARGS+=(--competitor "${_u}")'
fhas  "prospects.js threads competitor urls into pipeline" "${ENGINE}/prospects.js" "competitorUrls"
fhas  "run-analysis imports the competitors engine"      "${ENGINE}/run-analysis.js" "../../seo/engine/competitors.js"
fhas  "analyze.js calls probeCompetitors"                "${ENGINE}/analyze.js" "probeCompetitors("
ok    "prospects.sh rejects too many --competitor"       bash -c '! "'"${HELPER}"'" analyze acme-dental --competitor https://a --competitor https://b --competitor https://c --competitor https://d >/dev/null 2>&1'
ok    "prospects.sh rejects an invalid --competitor URL" bash -c '! "'"${HELPER}"'" analyze acme-dental --competitor not-a-url >/dev/null 2>&1'

# ===========================================================================
section "TEMPLATES — draft rendering (kinds, langs, placeholders; never sends)"
# ---------------------------------------------------------------------------
if [[ -n "${NODE}" ]]; then
  tests_run=$((tests_run+1))
  OUT="$(nodejs '
    import { pathToFileURL } from "node:url";
    const [tplP] = process.argv.slice(1);
    const T = await import(pathToFileURL(tplP).href);
    const errs = [];
    const prospect = { name:"Acme Dental", lastAnalysis:{ counts:{ critical:1, high:2, medium:3, low:0 } } };

    for (const kind of T.TEMPLATE_KINDS) {
      const en = T.renderTemplate(kind, { prospect, lang:"en" });
      if (!en.includes("Acme Dental")) errs.push(kind+"/en missing business name");
      if (!en.includes("[YOUR NAME]")) errs.push(kind+"/en missing operator placeholder");
      const ar = T.renderTemplate(kind, { prospect, lang:"ar" });
      if (!ar.includes("Acme Dental")) errs.push(kind+"/ar missing business name");
      if (!ar.includes("[اسمك]")) errs.push(kind+"/ar missing operator placeholder");
    }
    // audit-offer reflects the analysis counts (3 high-priority = 1 critical + 2 high).
    const offer = T.renderTemplate("audit-offer", { prospect, lang:"en" });
    if (!offer.includes("3 higher-priority")) errs.push("audit-offer did not use analysis counts");
    // unknown kind / lang throw.
    let t=0; try { T.renderTemplate("spam", { prospect }); } catch { t++; } if(!t) errs.push("unknown kind accepted");
    t=0; try { T.renderTemplate("intro", { prospect, lang:"de" }); } catch { t++; } if(!t) errs.push("unknown lang accepted");
    // banner makes clear nothing is sent.
    if (!/DRAFT/.test(T.draftBanner("en"))) errs.push("banner missing DRAFT notice");

    console.log(errs.length ? "FAIL: "+errs.join("; ") : "TEMPLATES_OK");
  ' "${ENGINE}/templates.js")"
  if [[ "${OUT}" == *TEMPLATES_OK* ]]; then _pass "templates: bilingual drafts with operator placeholders; analysis-aware; never sends"
  else _fail "templates wrong — ${OUT}"; fi
else
  _skip "templates (node not available)"
fi

# ===========================================================================
section "NO-SEND / NO-SCRAPE — the architectural boundary is enforced in code"
# ---------------------------------------------------------------------------
# The engine has ZERO third-party dependencies => it literally cannot pull in a
# mailer, an SMS/WhatsApp client, or a scraper. Assert that, plus the absence of
# any transport/scraper library token and any send/scrape ACTION or subcommand.
fhasnt "engine package.json declares NO dependencies" "${ENGINE}/package.json" '"dependencies"'

# Unambiguous transport/scraper library + integration tokens that would only appear
# in a real send/scrape integration (NOT in honest prose). Asserted absent across
# the engine, the helper, the lib and the cron installer.
SCAN=( "${ENGINE}"/*.js "${HELPER}" "${LIB}" "${CRON}" )
for tok in nodemailer createTransport sendgrid mailgun twilio puppeteer playwright cheerio serpapi googleapis nominatim smtplib; do
  tests_run=$((tests_run+1))
  if grep -rIl --binary-files=without-match -e "${tok}" "${SCAN[@]}" >/dev/null 2>&1; then
    _fail "forbidden transport/scraper token present: ${tok}"
  else
    _pass "no '${tok}' transport/scraper token in engine/scripts"
  fi
done

# The message renderer must be pure text — no network call of any kind.
fhasnt "templates.js makes NO fetch call" "${ENGINE}/templates.js" "fetch("
fhasnt "alert.js makes NO fetch call (pure builder)" "${ENGINE}/alert.js" "fetch("
# The action surface has no send/scrape/import/crawl/email/sms — only organize+analyze.
for bad in send scrape import crawl email sms outreach harvest; do
  ok "prospects-lib has NO '${bad}' action" bash -c '. "'"${LIB}"'"; ! prospects_contains '"${bad}"' "${PROSPECTS_ACTIONS}"'
done
# The CLI entrypoint has no "send" subcommand handler.
fhasnt "prospects.js has NO 'send' subcommand" "${ENGINE}/prospects.js" "cmd === 'send'"

# NO parallel analyzer: the prospects engine ships none of the SEO analyzer modules.
absent "no parallel probe.js"             "${ENGINE}/probe.js"
absent "no parallel rules.js"             "${ENGINE}/rules.js"
absent "no parallel scoring.js"           "${ENGINE}/scoring.js"
absent "no parallel report.js"            "${ENGINE}/report.js"
absent "no parallel lighthouse-adapter.js" "${ENGINE}/lighthouse-adapter.js"
# analyze.js REUSES the real SEO engine by importing it.
fhas  "analyze.js imports the SEO probe"  "${ENGINE}/analyze.js" "../../seo/engine/probe.js"
fhas  "analyze.js imports the SEO rules"  "${ENGINE}/analyze.js" "../../seo/engine/rules.js"
fhas  "analyze.js imports the SEO report" "${ENGINE}/analyze.js" "../../seo/engine/report.js"
# the SEO engine it reuses actually exists where expected.
exists "reused SEO probe is present"      "${SEOENGINE}/probe.js"

# ===========================================================================
section "SERVICE COMPOSE — profile-gated, internal, no ports, one-shot, pinned"
# ---------------------------------------------------------------------------
exists "prospects.compose.yml exists" "${SVC}"
if [[ -n "${PY}" ]]; then
  OUT="$(pyyaml "${SVC}" '
err = []
names = set(svcs.keys())
if names != {"prospects"}: err.append(f"services={names}")
for n, s in svcs.items():
    if "ports" in s: err.append(n + " has host ports")
    if s.get("profiles") != ["prospects"]: err.append(n + " not profile-gated [prospects]")
    if s.get("security_opt") != ["no-new-privileges:true"]: err.append(n + " missing no-new-privileges")
    if str(s.get("restart")) not in ("no", "False"): err.append(n + " restart not no: " + str(s.get("restart")))
    if "build" not in s: err.append(n + " has no build")
    img = s.get("image", "")
    if img.endswith(":latest") or (img and ":" not in img.split("/")[-1]): err.append(n + " image not pinned: " + img)
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
# Dockerfile: pinned base, never latest; copies BOTH engines (reuse).
fhas  "Dockerfile pins node:22-alpine"     "${DOCKERFILE}" "FROM node:22-alpine"
fhasnt "Dockerfile is NOT :latest"         "${DOCKERFILE}" ":latest"
fhas  "Dockerfile copies the SEO engine (reuse)" "${DOCKERFILE}" "seo/engine/"
fhas  "Dockerfile copies the prospects engine"   "${DOCKERFILE}" "prospects/engine/"
fhas  "prospects mem 256M (light)"         "${SVC}" "256M"

# ===========================================================================
section "BOOT PROFILES — the prospects service is NEVER in a boot profile"
# ---------------------------------------------------------------------------
fhasnt "boot-profiles.conf has NO prospects service" "${BOOTPROFILES}" "prospects"

# ===========================================================================
section "WIRING — .env, helper, lib, cron syntax/args, Dockerfile"
# ---------------------------------------------------------------------------
fhas ".env.example has PROSPECT section"   "${ENVX}" "CLIENT PROSPECT ORGANIZER"
fhas ".env.example has PROSPECTS_DATA_DIR=" "${ENVX}" "PROSPECTS_DATA_DIR="
fhas ".env.example has PROSPECTS_NOTIFY_CMD=" "${ENVX}" "PROSPECTS_NOTIFY_CMD="
# Post-analysis operator alert wiring: pure builder present; analyze dispatches it
# through the notify seam; the seam exposes notifyAnalysis; compose + env documented.
exists "engine alert.js exists"                 "${ENGINE}/alert.js"
exists "engine run-analysis.js (pipeline) exists" "${ENGINE}/run-analysis.js"
fhas  "run-analysis.js builds the alert (imports alert.js)" "${ENGINE}/run-analysis.js" "./alert.js"
fhas  "prospects.js drives the pipeline (runAnalysisPipeline)" "${ENGINE}/prospects.js" "runAnalysisPipeline("
fhas  "analyze dispatches notifyAnalysis"       "${ENGINE}/prospects.js" "notifyAnalysis(root"
fhas  "notify.js exports notifyAnalysis"        "${ENGINE}/notify.js" "export async function notifyAnalysis"
fhas  "notifyAnalysis reuses PROSPECTS_NOTIFY_CMD" "${ENGINE}/notify.js" "PROSPECTS_NOTIFY_CMD"
# AI-assisted DRAFT generator wiring: engine present + reuses the SEO ai.js seam; CLI +
# helper + lib expose `draft`; .env documents it (operator-only, reuses AI_*).
exists "engine drafts.js exists"                "${ENGINE}/drafts.js"
fhas  "drafts.js reuses the SEO ai.js seam"     "${ENGINE}/drafts.js" "../../seo/engine/ai.js"
fhas  "drafts.js uses getAiProvider + parseAiJson" "${ENGINE}/drafts.js" "getAiProvider, parseAiJson"
fhas  "prospects.js has a draft subcommand"     "${ENGINE}/prospects.js" "cmd === 'draft'"
fhas  "prospects.js imports the drafts engine"  "${ENGINE}/prospects.js" "./drafts.js"
fhas  "prospects.js stores drafts (recordDrafts)" "${ENGINE}/prospects.js" "recordDrafts("
fhas  "prospects.js show surfaces stored drafts" "${ENGINE}/prospects.js" "drafts:"
ok    "prospects-lib: draft is a valid action"  bash -c '. "'"${LIB}"'"; prospects_valid_action draft'
ok    "prospects-lib: outreach is a valid draft kind" bash -c '. "'"${LIB}"'"; prospects_valid_draft_kind outreach'
no    "prospects-lib: bogus draft kind rejected" bash -c '. "'"${LIB}"'"; prospects_valid_draft_kind bogus'
fhas  "prospects.sh has a draft action"         "${HELPER}" "  draft)"
fhas  "prospects.sh forwards --kind on draft"   "${HELPER}" 'ARGS+=(--kind'
fhas  ".env.example documents the draft generator" "${ENVX}" "draft <id>"
fhas  "compose passes PROSPECTS_REPORT_LOCALE"  "${SVC}" "PROSPECTS_REPORT_LOCALE"
fhas  ".env.example documents the analysis alert" "${ENVX}" "analysis complete"
fhas  ".env.example has PROSPECTS_REPORT_LOCALE=" "${ENVX}" "PROSPECTS_REPORT_LOCALE="
# FULL automated flow wiring: the single command (analyze --notify) + PDF + follow-up.
fhas  ".env.example documents the full automated flow" "${ENVX}" "analyze <id> --notify"
fhas  ".env.example has PROSPECTS_FOLLOWUP_DAYS=" "${ENVX}" "PROSPECTS_FOLLOWUP_DAYS="
fhas  ".env.example has PROSPECTS_REPORT_PDF="    "${ENVX}" "PROSPECTS_REPORT_PDF="
fhas  "compose passes PROSPECTS_FOLLOWUP_DAYS"   "${SVC}" "PROSPECTS_FOLLOWUP_DAYS"
fhas  "compose passes PROSPECTS_REPORT_PDF"      "${SVC}" "PROSPECTS_REPORT_PDF"
fhas  "compose passes SEO_PDF_RENDERER (optional PDF)" "${SVC}" "SEO_PDF_RENDERER"
fhas  "prospects.sh forwards --notify on analyze" "${HELPER}" 'ARGS+=(--notify)'
fhas  "prospects.sh forwards --pdf on analyze"    "${HELPER}" 'ARGS+=(--pdf)'
fhas  "prospects.sh forwards --locale on analyze" "${HELPER}" 'ARGS+=(--locale'
fhas  "store.js writes report artifacts (html/pdf)" "${ENGINE}/store.js" "export function writeReportArtifact"
fhas  "prospects.js reuses the SEO pdf-export"   "${ENGINE}/prospects.js" "../../seo/engine/pdf-export.js"
# BOUNDARY on the orchestrator: it owns NO network/scrape of its own (the SEO probe is
# the only fetch, inside analyze.js) — the pipeline file makes no direct fetch call.
fhasnt "run-analysis.js makes NO direct fetch"   "${ENGINE}/run-analysis.js" "fetch("
# BOUNDARY: the alert is operator-only — assert the explicit reminder lines exist and
# that NO outbound transport leaks into the alert/notify path (covered by the scan above).
fhas  "alert.js carries the operator-only boundary (en)" "${ENGINE}/alert.js" "NOT sent to the prospect"
fhas  "alert.js carries the operator-only boundary (ar)" "${ENGINE}/alert.js" "لم يُرسَل هذا إلى العميل"
# Helper + lib + cron syntax.
tests_run=$((tests_run+1)); if bash -n "${HELPER}" 2>/dev/null; then _pass "prospects.sh syntax ok"; else _fail "prospects.sh syntax error"; fi
tests_run=$((tests_run+1)); if bash -n "${LIB}" 2>/dev/null; then _pass "prospects-lib.sh syntax ok"; else _fail "prospects-lib.sh syntax error"; fi
tests_run=$((tests_run+1)); if bash -n "${CRON}" 2>/dev/null; then _pass "prospects-install-cron.sh syntax ok"; else _fail "prospects-install-cron.sh syntax error"; fi
# Helper arg validation (no docker: action/status/engine validated before need_docker).
ok "prospects.sh rejects a bad action"  bash -c '! "'"${HELPER}"'" bogus >/dev/null 2>&1'
ok "prospects.sh rejects a bad status"  bash -c '! "'"${HELPER}"'" add Acme --status nope >/dev/null 2>&1'
ok "prospects.sh rejects a bad engine"  bash -c '! "'"${HELPER}"'" analyze acme --engine chrome >/dev/null 2>&1'
ok "prospects.sh rejects a bad template" bash -c '! "'"${HELPER}"'" template spam acme >/dev/null 2>&1'
ok "prospects.sh help works"            bash -c '"'"${HELPER}"'" help >/dev/null 2>&1'
# Lib pure logic (sourced).
ok "lib: valid action add"              bash -c '. "'"${LIB}"'"; prospects_valid_action add'
ok "lib: valid action assist"           bash -c '. "'"${LIB}"'"; prospects_valid_action assist'
no "lib: rejects bad action"            bash -c '. "'"${LIB}"'"; prospects_valid_action bogus'
ok "lib: new->contacted allowed"        bash -c '. "'"${LIB}"'"; prospects_can_transition new contacted'
no "lib: new->won rejected"             bash -c '. "'"${LIB}"'"; prospects_can_transition new won'
ok "lib: valid id"                      bash -c '. "'"${LIB}"'"; prospects_valid_id acme-dental'
no "lib: rejects trailing -"            bash -c '. "'"${LIB}"'"; prospects_valid_id bad-'
ok "lib: valid date"                    bash -c '. "'"${LIB}"'"; prospects_valid_date 2026-06-01'
no "lib: rejects bad date shape"        bash -c '. "'"${LIB}"'"; prospects_valid_date 2026/06/01'
ok "lib: valid http url"                bash -c '. "'"${LIB}"'"; prospects_valid_url https://x.example'
no "lib: rejects ftp url"               bash -c '. "'"${LIB}"'"; prospects_valid_url ftp://x'
# engine package.json declares ESM (so the container runs the modules unambiguously).
fhas "engine package.json is type:module" "${ENGINE}/package.json" '"type": "module"'

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
