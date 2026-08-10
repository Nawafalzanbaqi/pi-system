// pi-system prospect organizer — PUBLIC-SITE analysis by REUSING services/seo.
// ===========================================================================
// This is the analysis seam, and it deliberately contains NO analyzer of its own.
// It is a thin orchestration layer over the EXISTING SEO engine in services/seo —
// the SAME probe, the SAME deterministic rules, the SAME report renderer, and the
// SAME optional-and-inert AI enrichment that growth-layer #3 ships. We do NOT
// build a parallel analyzer: every import below comes from ../../seo/engine.
//
// WHAT IT DOES (and is allowed to do): given a prospect's OWN PUBLIC website URL
// that the operator entered, fetch that one public page like any visitor would and
// produce a professional "here's what I noticed" report (performance / SEO /
// accessibility / best-practice gaps). Anyone may fetch a public website; this is
// not scraping a platform, it is reading the prospect's own site once. The output
// is a clean Markdown artifact the operator reviews, edits and uses as a
// CONVERSATION STARTER when they reach out MANUALLY.
//
// WHAT IT MUST NOT DO (architectural boundary): it never touches Google Maps,
// LinkedIn, search results, or any ToS-protected platform; it never enumerates or
// bulk-fetches; and it never contacts the prospect. It fetches exactly the one URL
// the operator typed in.
//
// PURITY/TESTABILITY: the only impure step (the HTTP fetch) lives inside the SEO
// engine's probeUrl behind an injectable `fetchImpl`, and the AI call behind its
// own injectable fetch — so the whole path is exercised offline in tests with a
// mocked fetch (NO real network) and with fixture audit JSON.
// ===========================================================================

// Genuine reuse — these are the SEO engine modules, not copies.
import { probeUrl } from '../../seo/engine/probe.js';
import { analyze as analyzeRules, summarize } from '../../seo/engine/rules.js';
import { enrich } from '../../seo/engine/ai.js';
import { renderReport, renderSummary } from '../../seo/engine/report.js';
import { fromLighthouse } from '../../seo/engine/lighthouse-adapter.js';
import { capabilitiesFor, isValidDepth } from '../../seo/engine/depth.js';
import { MAX_COMPETITORS, compareSites, probeCompetitors } from '../../seo/engine/competitors.js';

function nowIso(deps) {
  return new Date(deps && deps.now ? deps.now() : Date.now()).toISOString();
}

// ---------------------------------------------------------------------------
// reportFromAudit(audit, env, deps) -> { audit, findings, report, summary, counts, ai }
// Given an AUDIT object (from the SEO probe OR the SEO Lighthouse adapter), reuse
// the SEO rules + report + AI seam to produce the shareable artifact. Pure aside
// from the optional AI call (injectable). This is the function the tests feed a
// FIXTURE audit to verify report generation reuses the SEO engine.
//
// deps.depth, when set, controls whether the AI enrichment runs:
//   - 'quick'                -> NO AI call (0 fetches), the deterministic path only
//   - 'standard' / 'deep'    -> the existing single-call enrichment (inert w/o a key)
// Unset / unknown values keep the back-compat behaviour (enrich always called).
// ---------------------------------------------------------------------------
export async function reportFromAudit(audit, env = {}, deps = {}) {
  const findings = analyzeRules(audit); // SEO rules.js — the deterministic engine
  const caps = isValidDepth(deps.depth) ? capabilitiesFor(deps.depth) : { ai: true, panel: false };
  // Pin the level on the audit BEFORE rendering so the report header reflects it
  // (the pipeline also sets this on its own result; this keeps reportFromAudit
  // standalone so a unit test feeding a fixture audit sees the right header).
  if (isValidDepth(deps.depth)) audit.depth = deps.depth;
  const enriched = caps.ai
    ? await enrich(findings, audit, env, { fetchImpl: deps.aiFetchImpl })
    : { findings, ai: { enabled: false, provider: 'none', suggestions: [], actionPlan: [], executiveSummary: null } };
  const report = renderReport(audit, findings, { ai: enriched.ai }); // SEO report.js
  const summary = renderSummary(audit, findings);
  const counts = summarize(findings);
  return { audit, findings, report, summary, counts, ai: enriched.ai };
}

// ---------------------------------------------------------------------------
// analyzeProspect(prospect, env, deps) -> the same shape as reportFromAudit.
//   deps.engine     'probe' (default, free, no browser) | 'lighthouse'
//   deps.fetchImpl  injectable fetch for the probe (tests pass a stub HTML page)
//   deps.aiFetchImpl injectable fetch for the optional AI call (inert without a key)
//   deps.resolve    injectable DNS resolver for the probe's SSRF guard (tests pass a
//                   stub so NO real DNS happens; production uses node:dns)
//   deps.lhr        a parsed Lighthouse JSON result (required for engine=lighthouse)
//   deps.now        injectable clock (for the timestamp)
// The default 'probe' engine fetches ONLY the prospect's own public URL via the
// SEO engine's probeUrl. The 'lighthouse' engine ingests a Lighthouse JSON the
// operator produced (e.g. via scripts/seo.sh) through the SEO adapter — opt-in,
// never the default, exactly like the SEO auditor.
// ---------------------------------------------------------------------------
export async function analyzeProspect(prospect, env = {}, deps = {}) {
  if (!prospect || !prospect.id) throw new Error('analyzeProspect needs a prospect with an id');
  const engine = String(deps.engine || 'probe');

  let audit;
  if (engine === 'lighthouse') {
    if (!deps.lhr) throw new Error("engine 'lighthouse' requires a parsed Lighthouse JSON (deps.lhr)");
    audit = fromLighthouse(deps.lhr, {
      name: prospect.id,
      url: prospect.url || deps.lhr.finalUrl || deps.lhr.requestedUrl || '',
      timestamp: nowIso(deps),
    });
  } else if (engine === 'probe') {
    if (!prospect.url) {
      throw new Error(`prospect '${prospect.id}' has no website URL to analyze — add one with: update ${prospect.id} --url https://...`);
    }
    // The ONLY network access: fetch the prospect's own public site, once — behind
    // the SEO engine's SSRF guard (env carries the PROSPECTS_PROBE_ALLOW_PRIVATE opt-in).
    audit = await probeUrl(prospect.id, prospect.url, { fetchImpl: deps.fetchImpl, now: deps.now, env, resolve: deps.resolve });
  } else {
    throw new Error(`unknown analyze engine '${engine}' (expected probe | lighthouse)`);
  }

  // Pin the analysis depth on the audit so the report header reflects the level
  // this run produced (the pipeline overrides this when it has the resolved value).
  if (isValidDepth(deps.depth)) audit.depth = deps.depth;

  // Competitor probing — operator-supplied URLs, bounded. Reuses the SAME SSRF-
  // guarded probe as the primary; a blocked/failed competitor is recorded and is
  // never fatal. Skipped silently when no competitors are supplied.
  const competitorUrls = Array.isArray(deps.competitorUrls) ? deps.competitorUrls : [];
  if (competitorUrls.length > MAX_COMPETITORS) {
    throw new Error(`too many competitor URLs (${competitorUrls.length}) — max ${MAX_COMPETITORS}`);
  }
  if (competitorUrls.length) {
    const competitorAudits = await probeCompetitors(competitorUrls, {
      fetchImpl: deps.fetchImpl, now: deps.now, env, resolve: deps.resolve,
    });
    audit.competitors = compareSites(audit, competitorAudits);
  }

  return reportFromAudit(audit, env, deps);
}
