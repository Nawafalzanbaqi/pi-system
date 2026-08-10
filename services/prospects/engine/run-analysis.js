// pi-system prospect organizer — the FULL automated analysis PIPELINE (pure orchestrator).
// ===========================================================================
// One operator command (`prospects.sh analyze <id> --notify`) runs the whole flow,
// end to end, for ONE operator-entered prospect:
//
//   audit  -> report -> [pdf] -> record -> alert -> [followup]
//
//   1. AUDIT     the SSRF-guarded full audit (all five SEO categories) of the
//                prospect's OWN public site, its verdict, and the OPTIONAL, inert-
//                until-keyed AI enrichment — ALL inside the reused services/seo engine
//                (the `analyze` seam). The env carries the optional AI key.
//   2. REPORT    persist the Markdown artifact the operator reviews & shares MANUALLY.
//   3. PDF       OPTIONAL, opt-in, Pi-aware: a print-ready HTML always, plus a PDF only
//                when a renderer is configured (degrades gracefully; never blocks).
//   4. RECORD    store the lastAnalysis pointer (keeps the verdict for a later assist).
//   5. ALERT     build the RICH heads-up (alert.js, pure) and deliver it TO THE OPERATOR
//                ONLY — the local file always, the channel push (Telegram/Kuma) only on
//                the full --notify run. NEVER to the prospect.
//   6. FOLLOWUP  on the full --notify run, schedule the operator's next nudge
//                (today + N days) — a reminder TO THE OPERATOR, surfaced by `followups`.
//
// PURE ORCHESTRATION: this module owns the ORDER and the pure builders only. EVERY
// impure step (the network probe, the AI call, every disk write, the PDF render, the
// operator notify) is an INJECTED seam in `deps` — there are NO defaults — so the whole
// order-of-operations is unit-tested offline with mocks (tests/prospects/run.sh), and
// the module cannot accidentally touch the network or disk on its own.
//
// BOUNDARY (architectural, not a toggle): there is NO send path and NO scrape path
// here. The ONLY outbound seam is `deliverAlert`, whose payload is the operator's own
// heads-up (it carries the operator-only reminder line and no prospect address). The
// operator still ADDS prospects manually and CONTACTS them manually.
// ===========================================================================

import { recordAnalysis, setFollowup } from './pipeline.js';
import { formatProspectAlert, formatProspectAlertSummary, formatReauditAlert, formatReauditAlertSummary } from './alert.js';
import { diffAudits, isMeaningfulChange } from '../../seo/engine/diff.js';
import { renderPanelSection } from '../../seo/engine/specialists.js';
import { resolveDepth, capabilitiesFor } from '../../seo/engine/depth.js';
import { MAX_COMPETITORS, renderCompetitorSection } from '../../seo/engine/competitors.js';

// The canonical phase labels, in the exact order the pipeline performs them. The
// optional phases ('pdf', 'followup') appear only when their step actually runs.
export const PIPELINE_PHASES = ['audit', 'report', 'pdf', 'record', 'alert', 'followup'];

// Arabic-first default, matching alert.js / report.js.
function normLocale(locale) {
  return String(locale || '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}

// followupDate(today, days) -> 'YYYY-MM-DD' that is `days` after `today`. Pure; no clock.
// Returns null for an unparseable date. Used to schedule the operator's next nudge.
export function followupDate(today, days) {
  const base = Date.parse(String(today) + 'T00:00:00Z');
  if (!Number.isFinite(base)) return null;
  const n = Number.isInteger(days) ? days : (Number.isFinite(days) ? Math.round(days) : 3);
  return new Date(base + n * 86400000).toISOString().slice(0, 10);
}

// runAnalysisPipeline(prospect, env, opts, deps) -> a structured result incl. `steps`.
//   opts = { engine, lhr, locale, notify, pdf, depth, panel, followupDays, today, now }
//     depth   one of 'quick' | 'standard' | 'deep' (validated; --panel is treated as
//             'deep' for back-compat). Unset => resolved from env via the shared rule
//             in depth.js (SEO_DEFAULT_DEPTH; else key-presence default).
//   deps (ALL injected — no defaults; the caller binds the real impls, tests pass mocks):
//     analyze(prospect, env, { engine, lhr, depth })  -> { audit, report, summary, counts, ai }
//     saveReport(id, ts, md)                   -> reportFile path
//     renderPdf(md, { title, lang })           -> { html, pdf, degraded, reason }   (pdf only)
//     saveArtifact(id, ts, ext, data)          -> artifact path                     (pdf only)
//     saveRecord(record)                       -> void  (persist the prospect record)
//     deliverAlert(alert, push)                -> notify result  (push=true => channel)
//     now()                                    -> ms  (optional clock; defaults to Date.now)
export async function runAnalysisPipeline(prospect, env = {}, opts = {}, deps = {}) {
  if (!prospect || !prospect.id) throw new Error('runAnalysisPipeline needs a prospect with an id');
  for (const k of ['analyze', 'saveReport', 'saveRecord', 'deliverAlert']) {
    if (typeof deps[k] !== 'function') throw new Error(`runAnalysisPipeline requires deps.${k}()`);
  }

  const steps = [];
  const nowMs = (typeof opts.now === 'function') ? opts.now() : Date.now();
  const ts = new Date(nowMs).toISOString();
  const locale = opts.locale;

  // Resolve the analysis depth ONCE here. The same precedence as the SEO CLI:
  // explicit opts.depth wins, legacy opts.panel = deep, else SEO_DEFAULT_DEPTH,
  // else 'standard' when AI is enabled / 'quick' when it isn't. Validated — an
  // unknown value throws BEFORE the network probe so a typo never spends a fetch.
  const depth = resolveDepth({ depth: opts.depth, panel: opts.panel }, env);
  const caps = capabilitiesFor(depth);

  // Competitor URLs — operator-supplied, bounded. Threaded into the analyze seam
  // so a blocked competitor is recorded by the SAME SSRF guard the primary uses.
  // Bound-check here too (defence in depth — the helper script also checks).
  const competitorUrls = Array.isArray(opts.competitorUrls) ? opts.competitorUrls : [];
  if (competitorUrls.length > MAX_COMPETITORS) {
    throw new Error(`too many competitor URLs (${competitorUrls.length}) — max ${MAX_COMPETITORS}`);
  }

  // 1) AUDIT — full SSRF-guarded audit -> verdict -> optional AI enrichment -> Markdown,
  //    all within the reused SEO engine. env carries the optional AI key (inert without).
  //    `depth` is threaded into the analyze seam so quick depth makes NO AI fetch.
  //    `competitorUrls` is threaded too so the analyze seam (which already owns the
  //    SSRF-guarded probe seam) probes each competitor under the SAME guard.
  const result = await deps.analyze(prospect, env, {
    engine: opts.engine, lhr: opts.lhr, depth, competitorUrls,
  });
  if (!result || !result.audit) throw new Error('the analyze seam returned no audit');
  result.audit.depth = depth; // pin the level on the audit (the report header shows it)
  steps.push('audit');

  // 1c) COMPETITOR SECTION — append the side-by-side to the SAVED report when
  //     the analyze seam produced a comparison (operator-supplied URLs). Strictly
  //     additive: with no competitors, the report is unchanged.
  if (result.audit.competitors
    && Array.isArray(result.audit.competitors.competitors)
    && result.audit.competitors.competitors.length) {
    result.report = `${result.report}\n${renderCompetitorSection(result.audit.competitors, { locale })}`;
    steps.push('competitors');
  }

  // 1b) SPECIALIST PANEL — only at deep depth (the "technical team" layer). When the
  //     caller injects deps.runPanel, attach the panel bundle to the audit and append
  //     its section to the report BEFORE it is saved. Inert without an AI key
  //     (deterministic templates); additive, so a quick/standard run is unchanged. The
  //     alert then surfaces the single #1 cross-cutting priority.
  if (caps.panel && typeof deps.runPanel === 'function') {
    const bundle = await deps.runPanel(result.audit);
    if (bundle) {
      result.audit.panel = bundle;
      result.report = `${result.report}\n${renderPanelSection(bundle, { locale })}`;
      steps.push('panel');
    }
  }

  // 2) REPORT — persist the shareable Markdown the operator reviews & sends themselves.
  const reportFile = deps.saveReport(prospect.id, ts, result.report);
  steps.push('report');

  // 3) PDF — OPTIONAL & opt-in. Always emit print-ready HTML; add a PDF only when a
  //    renderer is configured. Degrades gracefully — a missing renderer is not an error.
  let htmlFile = null;
  let pdfFile = null;
  let pdfDegraded = null;
  let pdfReason = '';
  if (opts.pdf) {
    if (typeof deps.renderPdf !== 'function' || typeof deps.saveArtifact !== 'function') {
      throw new Error('opts.pdf requires deps.renderPdf() and deps.saveArtifact()');
    }
    const rendered = await deps.renderPdf(result.report, {
      title: `${prospect.name || prospect.id} — report`,
      lang: normLocale(locale),
    });
    htmlFile = deps.saveArtifact(prospect.id, ts, 'html', rendered.html);
    if (rendered.pdf) pdfFile = deps.saveArtifact(prospect.id, ts, 'pdf', rendered.pdf);
    pdfDegraded = !!rendered.degraded;
    pdfReason = rendered.reason || '';
    steps.push('pdf');
  }

  // 4) RECORD — store the lastAnalysis pointer (the verdict is kept so the later,
  //    optional `assist` can read it without re-probing).
  let record = recordAnalysis(prospect, {
    engine: result.audit.engine,
    url: result.audit.url || prospect.url,
    reportFile,
    scores: result.audit.scores,
    verdict: result.audit.verdict,
    counts: result.counts,
    summary: result.summary,
  }, ts);
  deps.saveRecord(record);
  steps.push('record');

  // 5) ALERT — build the rich operator heads-up (pure) and deliver it. The local file
  //    is always written by the seam; the channel push fires only on the full --notify
  //    run (push = opts.notify). It carries the operator-only boundary line; NEVER the prospect.
  const alertAudit = {
    ...result.audit,
    name: prospect.name, // the human business name, not the storage id
    url: result.audit.url || prospect.url,
    reportFile,
    aiAssist: (record.ai_assist && record.ai_assist.enabled) ? record.ai_assist : null,
  };
  const full = formatProspectAlert(alertAudit, { locale });
  const summary = formatProspectAlertSummary(alertAudit, { locale });
  const label = (alertAudit.verdict && alertAudit.verdict.tier) || 'analysis';
  const alert = await deps.deliverAlert({ full, summary, label }, !!opts.notify);
  steps.push('alert');

  // 5b) RE-AUDIT REGRESSION ALERT — OPTIONAL, for monitoring an EXISTING client. When
  //     the caller injects deps.readPrevious(id) (the prior stored audit), diff the new
  //     audit against it and, ONLY on a MEANINGFUL regression (a new critical/high
  //     finding, a tier drop, or the site going offline), push a concise operator
  //     heads-up through the SAME deliverAlert seam (operator-only; NEVER the prospect).
  //     Inert unless readPrevious is wired, so a first-time analysis is unaffected.
  let diff = null;
  if (typeof deps.readPrevious === 'function') {
    const previous = await deps.readPrevious(prospect.id);
    diff = diffAudits(previous, result.audit);
    result.audit.diff = diff;
    if (isMeaningfulChange(diff)) {
      const reAudit = { ...alertAudit, diff };
      await deps.deliverAlert({
        full: formatReauditAlert(reAudit, { locale }),
        summary: formatReauditAlertSummary(reAudit, { locale }),
        label: 'regression',
      }, !!opts.notify);
      steps.push('reaudit');
    }
  }

  // 6) FOLLOW-UP — on the full automated run, schedule the operator's next nudge. A
  //    reminder TO THE OPERATOR (surfaced by `followups`), never an outbound message.
  //    Plain `analyze` (no --notify) leaves the pipeline status/date untouched.
  let followup = null;
  if (opts.notify) {
    const today = (opts.today && String(opts.today)) || ts.slice(0, 10);
    followup = followupDate(today, opts.followupDays);
    record = setFollowup(record, followup, ts);
    deps.saveRecord(record);
    steps.push('followup');
  }

  return {
    steps,
    ts,
    depth,
    audit: result.audit,
    report: result.report,
    summary: result.summary,
    counts: result.counts,
    ai: result.ai,
    reportFile,
    htmlFile,
    pdfFile,
    pdfDegraded,
    pdfReason,
    alert,
    diff,
    panel: (result.audit && result.audit.panel) || null,
    competitors: (result.audit && result.audit.competitors) || null,
    record,
    followup,
  };
}
