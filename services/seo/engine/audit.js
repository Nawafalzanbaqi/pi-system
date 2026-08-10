#!/usr/bin/env node
// pi-system SEO engine — CLI entrypoint (the container's ENTRYPOINT).
// ===========================================================================
// Subcommands (scripts/seo.sh drives these; they also run standalone with node):
//
//   audit  --name <n> --url <u> [--engine probe|lighthouse] [--lh-json <f>]
//          run ONE audit: probe (default, free, no browser) OR ingest a Lighthouse
//          JSON result, score it, store it, produce rule-based recommendations
//          (+ optional AI enrichment if AI_PROVIDER + AI_API_KEY are set), write a
//          report and push an optional one-line summary. Always records something.
//   reaudit --name <n> --url <u>
//                            re-run the probe on an EXISTING site and surface WHAT
//                            CHANGED vs the previous run: stores the new audit, writes a
//                            report with a "Changes since last audit" section, and pushes
//                            a concise operator heads-up via the gated notifier ONLY on a
//                            MEANINGFUL change (new critical/high, tier drop, or offline).
//   recommend --name <n>     re-run the rules + report on the site's LATEST stored
//                            audit (no new network probe). Useful after toggling AI.
//   report-pdf --name <n> [--md <file>] [--locale ar|en]
//                            OPTIONAL export: convert a report's Markdown to a clean,
//                            print-ready HTML and (if a renderer is opt-in) a PDF,
//                            written next to the .md under reports/. With --md it
//                            converts that EXISTING report file; otherwise it builds
//                            the bilingual prospect report from the LATEST stored
//                            audit. Off by default + degrades to the Markdown/HTML if
//                            no renderer is configured (see pdf-export.js).
//   content-ideas [--locale ar|en] [--per-site <N>]
//                            mine YOUR OWN accumulated audit history (the SEO audits JSONL
//                            + best-effort the prospects store) for recurring issue patterns
//                            and propose data-backed, educational content topics to attract
//                            inbound clients. Reads ONLY local data — scrapes/sends nothing.
//                            AI-assisted (reuses AI_*); inert without a key (templates).
//   list                     list audited sites with their latest scores.
//   trend  --name <n>        show per-category first→latest score deltas.
//
// Results live under --root (default $SEO_DATA_DIR or /data) — see store.js. Pure
// engine modules do the work; this file is just argument plumbing + I/O.
// ===========================================================================

import { probeUrl } from './probe.js';
import { fromLighthouse } from './lighthouse-adapter.js';
import { analyze, summarize } from './rules.js';
import { enrich } from './ai.js';
import { renderReport, renderSummary, buildProspectReport } from './report.js';
import { diffAudits, isMeaningfulChange, summarizeDiff } from './diff.js';
import { analyzeIssuePatterns, generateContentIdeas, auditsFromProspectsDb } from './content-ideas.js';
import { runSpecialistPanel, renderPanelSection } from './specialists.js';
import { resolveDepth, capabilitiesFor } from './depth.js';
import {
  MAX_COMPETITORS, compareSites, probeCompetitors, renderCompetitorSection,
} from './competitors.js';
import {
  appendAudit, writeReport, writeReportArtifact, latestReport,
  readAudits, readLatest, listSites, trend, isValidName, readRecentAuditsAcrossSites,
} from './store.js';
import { renderReportPdf } from './pdf-export.js';
import { notify } from './notify.js';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

// Flags that are LEGITIMATELY repeatable on the CLI accumulate into an array;
// every other flag is single-valued (last-wins is unreachable because the helper
// scripts only ever pass each non-repeatable flag once). Keep this list short
// and explicit so a typo can't silently collect somewhere unexpected.
const REPEATABLE_FLAGS = new Set(['competitor']);

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const a = argv[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = argv[i + 1];
      const value = (next === undefined || next.startsWith('--')) ? true : next;
      if (value !== true) i += 1;
      if (REPEATABLE_FLAGS.has(key)) {
        if (!Array.isArray(out[key])) out[key] = [];
        if (value !== true) out[key].push(value);
      } else {
        out[key] = value;
      }
    } else {
      out._.push(a);
    }
  }
  // Empty-array normalisation for repeatable flags so callers can safely read .length.
  for (const k of REPEATABLE_FLAGS) if (out[k] === undefined) out[k] = [];
  return out;
}

function fail(msg) {
  process.stderr.write(`[seo-engine] error: ${msg}\n`);
  process.exit(1);
}

// The audit stored just BEFORE the latest one (the comparison point for a re-audit
// diff), or null when there is no prior run. Reads the append-only history.
function previousAudit(root, name) {
  const h = readAudits(root, name);
  return h.length >= 2 ? h[h.length - 2] : null;
}

// Best-effort, LOCAL read of the prospects store so content ideas can ALSO mine the
// prospects' stored analyses. Defensive: if PROSPECTS_DATA_DIR is unset / not reachable
// (e.g. not mounted in this container) / malformed, it yields [] — it NEVER throws and
// NEVER reaches the network. Reads a local file only; no scrape, no send.
function readProspectsAuditsBestEffort() {
  try {
    const dir = String(process.env.PROSPECTS_DATA_DIR || '').trim();
    if (!dir) return [];
    const db = JSON.parse(readFileSync(join(dir, 'prospects.json'), 'utf8'));
    return auditsFromProspectsDb(db);
  } catch {
    return [];
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0] || 'audit';
  const root = String(args.root || process.env.SEO_DATA_DIR || '/data');

  if (cmd === 'list') {
    const sites = listSites(root);
    if (sites.length === 0) { process.stdout.write('No audits stored yet.\n'); return; }
    process.stdout.write('Site                 SEO  Perf A11y  BP   Last audited\n');
    for (const name of sites) {
      const a = readLatest(root, name) || {};
      const s = a.scores || {};
      const p = (n) => String(n ?? '—').padStart(4);
      process.stdout.write(
        `${name.padEnd(20)} ${p(s.seo)} ${p(s.performance)} ${p(s.accessibility)} ${p(s['best-practices'])}  ${a.timestamp || '—'}\n`,
      );
    }
    return;
  }

  if (cmd === 'trend') {
    const name = String(args.name || '');
    if (!isValidName(name)) fail(`invalid or missing --name (got '${name}')`);
    const t = trend(readAudits(root, name));
    if (t.runs === 0) { process.stdout.write(`No audit history for '${name}'.\n`); return; }
    process.stdout.write(`Trend for ${name} over ${t.runs} run(s):\n`);
    for (const [cat, v] of Object.entries(t.categories)) {
      const d = v.delta === null ? '' : ` (${v.delta >= 0 ? '+' : ''}${v.delta})`;
      process.stdout.write(`  ${cat.padEnd(16)} ${v.first ?? '—'} → ${v.latest ?? '—'}${d}\n`);
    }
    return;
  }

  if (cmd === 'content-ideas') {
    // Mine the operator's OWN accumulated audit history for recurring issue patterns and
    // propose data-backed, educational content topics to attract inbound clients. Reads
    // ONLY local stores (the SEO audits JSONL + best-effort the prospects store) — it
    // scrapes nothing and sends nothing. AI is reused but inert without a key.
    const loc = String(args.locale && args.locale !== true ? args.locale : (process.env.SEO_REPORT_LOCALE || 'ar'));
    const onlyLocale = (loc === 'en') ? 'en' : 'ar';
    const both = !args.locale || args.locale === true; // no --locale => show both languages
    const perSite = Number.parseInt(String(args['per-site'] || process.env.SEO_IDEAS_PER_SITE || '5'), 10) || 5;

    // Gather audits from the operator's OWN local stores (bounded; NO network/scrape).
    let audits = readRecentAuditsAcrossSites(root, { perSite });
    audits = audits.concat(readProspectsAuditsBestEffort());

    const patterns = analyzeIssuePatterns(audits);
    const res = await generateContentIdeas(patterns, process.env, {});

    process.stdout.write('# Content ideas — mined from YOUR OWN audit history\n');
    process.stdout.write(res.enabled
      ? `(AI-assisted via ${res.provider} — reads only your local data; operator-only, nothing is sent)\n`
      : '(deterministic templates — set AI_PROVIDER + AI_API_KEY for AI-assisted ideas; reads only local data, nothing is sent)\n');
    if (res.note) process.stdout.write(`_${res.note}_\n`);

    process.stdout.write('\n## Recurring issue patterns (most common first)\n');
    if (patterns.length === 0) {
      process.stdout.write('  (no audit history yet — run some audits first: ./scripts/seo.sh audit <site>)\n');
    } else {
      process.stdout.write(`  ${'occ'.padStart(4)} ${'sites'.padStart(5)} ${'%sites'.padStart(6)}  ${'category'.padEnd(15)} finding\n`);
      for (const p of patterns.slice(0, 12)) {
        process.stdout.write(`  ${String(p.occurrences).padStart(4)} ${String(p.sites).padStart(5)} ${(p.pctOfSites + '%').padStart(6)}  ${String(p.category).padEnd(15)} ${p.title} (${p.findingId})\n`);
      }
    }

    process.stdout.write('\n## Content topic ideas (educational / inbound — never about a named client)\n');
    let n = 1;
    for (const idea of res.ideas) {
      if (!both && idea.locale !== onlyLocale) continue;
      process.stdout.write(`\n### ${n}. [${idea.locale}] ${idea.title}\n`);
      process.stdout.write(`   angle:    ${idea.angle}\n`);
      process.stdout.write(`   audience: ${idea.targetAudience}\n`);
      process.stdout.write(`   based on: ${idea.basedOnPattern}\n`);
      n += 1;
    }
    process.stderr.write('[seo-engine] These are topic ideas for YOU to write — this tool reads only your local data and sends nothing.\n');
    return;
  }

  if (cmd === 'recommend') {
    const name = String(args.name || '');
    if (!isValidName(name)) fail(`invalid or missing --name (got '${name}')`);
    const audit = readLatest(root, name);
    if (!audit) fail(`no stored audit for '${name}' — run an audit first`);

    // Resolve the depth for this re-run; --depth wins, --panel back-compat, else
    // the key-presence default. Validated here so an unknown value never proceeds.
    let depth; let caps;
    try {
      depth = resolveDepth({ depth: args.depth, panel: args.panel }, process.env);
      caps = capabilitiesFor(depth);
    } catch (e) { fail(String(e.message || e)); }
    audit.depth = depth; // the report header pins the level this re-run produced

    const findings = analyze(audit);
    const enriched = caps.ai
      ? await enrich(findings, audit, process.env)
      : { findings, ai: { enabled: false, provider: 'none', suggestions: [], actionPlan: [], executiveSummary: null } };
    let report = renderReport(audit, findings, { ai: enriched.ai });
    if (caps.panel) {
      const ploc = String(process.env.SEO_REPORT_LOCALE || 'ar');
      const bundle = await runSpecialistPanel(audit, process.env, {});
      report = report + '\n' + renderPanelSection(bundle, { locale: ploc });
    }
    // If the latest stored audit carries a competitor comparison, re-render it so
    // `recommend` reproduces the section the original audit emitted (additive).
    if (audit.competitors && Array.isArray(audit.competitors.competitors) && audit.competitors.competitors.length) {
      const cloc = String(process.env.SEO_REPORT_LOCALE || 'ar');
      report = report + '\n' + renderCompetitorSection(audit.competitors, { locale: cloc });
    }
    const file = writeReport(root, name, audit.timestamp, report);
    process.stdout.write(report + '\n');
    process.stderr.write(`[seo-engine] depth=${depth}\n`);
    process.stderr.write(`[seo-engine] report -> ${file}\n`);
    return;
  }

  if (cmd === 'report-pdf') {
    const name = String(args.name || '');
    if (!isValidName(name)) fail(`invalid or missing --name (got '${name}')`);
    const locale = String(args.locale && args.locale !== true ? args.locale : (process.env.SEO_REPORT_LOCALE || 'ar'));

    // Depth selects which layers run when we (re)build the prospect report. With
    // --md (convert an EXISTING report file) depth is informational only — the
    // Markdown was already produced at whatever depth it was authored at.
    let depth; let caps;
    try {
      depth = resolveDepth({ depth: args.depth, panel: args.panel }, process.env);
      caps = capabilitiesFor(depth);
    } catch (e) { fail(String(e.message || e)); }

    // Resolve the Markdown to convert: an EXPLICIT existing file (--md), else build
    // the bilingual prospect report from the site's latest stored audit.
    let md; let source;
    if (args.md && args.md !== true) {
      try { md = readFileSync(String(args.md), 'utf8'); } catch (e) { fail(`could not read --md file: ${e.message || e}`); }
      source = `existing Markdown report (${args.md})`;
    } else {
      const audit = readLatest(root, name);
      if (!audit) fail(`no stored audit for '${name}' — run an audit first, or pass --md <existing report.md>`);
      audit.depth = depth; // the report header pins the level this rebuild produced
      const findings = analyze(audit);
      const enriched = caps.ai
        ? await enrich(findings, audit, process.env)
        : { findings, ai: { enabled: false, provider: 'none', suggestions: [], actionPlan: [], executiveSummary: null } };
      // Attach the re-audit diff vs the previous run (additive; baseline => no section).
      const diff = diffAudits(previousAudit(root, name), audit);
      // Specialist panel only at the deepest level — additive, inert without a key.
      const panel = caps.panel ? await runSpecialistPanel(audit, process.env, {}) : null;
      md = buildProspectReport({ ...audit, findings, diff, panel }, { locale, ai: enriched.ai });
      source = `prospect report (locale ${locale}, depth ${depth}) from the latest stored audit`;
    }

    const ts = new Date().toISOString();
    // Persist the exact Markdown that was converted, then the print-ready HTML, then
    // the PDF only if a renderer is opt-in (see pdf-export.js → graceful degrade).
    const mdFile = writeReportArtifact(root, name, ts, 'md', md);
    const { html, pdf, degraded, reason } = await renderReportPdf(md, { title: `${name} — report`, lang: locale }, { env: process.env });
    const htmlFile = writeReportArtifact(root, name, ts, 'html', html);
    const pdfFile = pdf ? writeReportArtifact(root, name, ts, 'pdf', pdf) : null;

    process.stdout.write(`Source:   ${source}\n`);
    process.stdout.write(`Markdown: ${mdFile}\n`);
    process.stdout.write(`HTML:     ${htmlFile}\n`);
    if (pdfFile) {
      process.stdout.write(`PDF:      ${pdfFile}\n`);
    } else {
      process.stdout.write('PDF:      (not produced)\n');
      process.stderr.write(`[seo-engine] ${reason}\n`);
    }
    process.stderr.write(`[seo-engine] degraded=${degraded}\n`);
    return;
  }

  if (cmd === 'audit') {
    const name = String(args.name || '');
    if (!isValidName(name)) fail(`invalid or missing --name (got '${name}')`);
    const engine = String(args.engine || 'probe');

    // Resolve the analysis depth BEFORE any work happens. --depth wins; legacy
    // --panel (and the legacy env SEO_AI_PANEL=1) is treated as --depth deep;
    // otherwise SEO_DEFAULT_DEPTH; otherwise 'standard' when AI is enabled,
    // 'quick' when it isn't. Validated here so an unknown value never spends a
    // probe call.
    let depth; let caps;
    try {
      depth = resolveDepth({ depth: args.depth, panel: args.panel }, process.env);
      caps = capabilitiesFor(depth);
    } catch (e) { fail(String(e.message || e)); }

    let audit;
    if (engine === 'lighthouse') {
      const lhPath = String(args['lh-json'] || '');
      if (!lhPath) fail('--engine lighthouse requires --lh-json <path to lighthouse json>');
      const url = String(args.url || '');
      const lhr = JSON.parse(readFileSync(lhPath, 'utf8'));
      audit = fromLighthouse(lhr, { name, url: url || lhr.finalUrl || lhr.requestedUrl || '', timestamp: new Date().toISOString() });
    } else if (engine === 'probe') {
      const url = String(args.url || '');
      if (!url) fail('--engine probe requires --url <site url>');
      audit = await probeUrl(name, url, {});
    } else {
      fail(`unknown --engine '${engine}' (expected probe | lighthouse)`);
    }

    audit.depth = depth; // pin the level on the stored audit + the report header

    // Competitors — operator-supplied URLs, bounded (MAX_COMPETITORS). Each goes
    // through the SAME SSRF-guarded probe as the primary; a blocked/failed
    // competitor is recorded with its non-leaky reason and is never fatal.
    const competitorUrls = Array.isArray(args.competitor) ? args.competitor : [];
    if (competitorUrls.length > MAX_COMPETITORS) {
      fail(`too many --competitor URLs (${competitorUrls.length}) — max ${MAX_COMPETITORS}`);
    }
    let comparison = null;
    if (competitorUrls.length) {
      const competitorAudits = await probeCompetitors(competitorUrls, {});
      comparison = compareSites(audit, competitorAudits);
      audit.competitors = comparison; // persisted with the audit so reports can re-render it
    }

    appendAudit(root, name, audit);
    const findings = analyze(audit);
    // Depth gates the SINGLE-call AI enrichment. At quick depth we make NO AI call
    // (no fetch); at standard/deep we run the existing enrich (inert without a key).
    const enriched = caps.ai
      ? await enrich(findings, audit, process.env)
      : { findings, ai: { enabled: false, provider: 'none', suggestions: [], actionPlan: [], executiveSummary: null } };
    let report = renderReport(audit, findings, { ai: enriched.ai });
    const counts = summarize(findings);
    const summary = renderSummary(audit, findings);

    // Multi-specialist panel — only at deep depth (the full "technical team"). Each
    // specialist + the synthesis is one AI call (see the cost note in .env.example).
    // Inert without an AI key (deterministic templates); additive + best-effort.
    if (caps.panel) {
      const ploc = String(process.env.SEO_REPORT_LOCALE || 'ar');
      const bundle = await runSpecialistPanel(audit, process.env, {});
      report = report + '\n' + renderPanelSection(bundle, { locale: ploc });
    }
    // Competitor comparison — additive section appended when competitor URLs were
    // supplied. All numbers are REAL audit fields (no synthesis).
    if (comparison) {
      const cloc = String(process.env.SEO_REPORT_LOCALE || 'ar');
      report = report + '\n' + renderCompetitorSection(comparison, { locale: cloc });
    }
    const file = writeReport(root, name, audit.timestamp, report);

    await notify(root, summary, counts, process.env, {});

    process.stdout.write(report + '\n');
    process.stderr.write(`[seo-engine] depth=${depth}\n`);
    process.stderr.write(`[seo-engine] ${summary}\n`);
    process.stderr.write(`[seo-engine] report -> ${file}\n`);
    if (comparison) {
      const blocked = comparison.competitors.filter((x) => !x.ok).length;
      process.stderr.write(`[seo-engine] competitors: ${comparison.competitors.length} probed, ${blocked} blocked/failed\n`);
    }
    return;
  }

  if (cmd === 'reaudit') {
    // Re-audit an EXISTING site and surface WHAT CHANGED vs the previous run — the
    // ongoing MONITORING path. Re-runs the SAME SSRF-guarded probe, appends to history,
    // diffs against the previous audit, writes a report with a "Changes since last
    // audit" section, and pushes a concise operator heads-up via the SAME gated SEO
    // notifier ONLY on a MEANINGFUL change (a new critical/high, a tier drop, or the
    // site going offline). Never contacts anyone but the operator's own channel.
    const name = String(args.name || '');
    if (!isValidName(name)) fail(`invalid or missing --name (got '${name}')`);
    const url = String(args.url || '');
    if (!url) fail('reaudit requires --url <site url> (it re-runs the SSRF-guarded probe)');
    const locale = String(args.locale && args.locale !== true ? args.locale : (process.env.SEO_REPORT_LOCALE || 'ar'));

    // Same depth resolution as audit/recommend so monitoring stays consistent with
    // a manual audit on the same site. --depth wins; --panel back-compat; else env;
    // else the key-presence default. Validated before the probe runs.
    let depth; let caps;
    try {
      depth = resolveDepth({ depth: args.depth, panel: args.panel }, process.env);
      caps = capabilitiesFor(depth);
    } catch (e) { fail(String(e.message || e)); }

    const previous = readLatest(root, name);          // the run we diff against (null => baseline)
    const audit = await probeUrl(name, url, {});       // same guarded probe as `audit`
    audit.depth = depth;                                // pin the level on this run too

    // Competitors on a monitoring re-audit — same SSRF guard, same bound. Optional.
    const competitorUrls = Array.isArray(args.competitor) ? args.competitor : [];
    if (competitorUrls.length > MAX_COMPETITORS) {
      fail(`too many --competitor URLs (${competitorUrls.length}) — max ${MAX_COMPETITORS}`);
    }
    let comparison = null;
    if (competitorUrls.length) {
      const competitorAudits = await probeCompetitors(competitorUrls, {});
      comparison = compareSites(audit, competitorAudits);
      audit.competitors = comparison;
    }

    appendAudit(root, name, audit);

    const delta = diffAudits(previous, audit);
    const findings = analyze(audit);
    const enriched = caps.ai
      ? await enrich(findings, audit, process.env)
      : { findings, ai: { enabled: false, provider: 'none', suggestions: [], actionPlan: [], executiveSummary: null } };
    const panel = caps.panel ? await runSpecialistPanel(audit, process.env, {}) : null;
    const md = buildProspectReport({ ...audit, findings, diff: delta, panel, competitors: comparison }, { locale, ai: enriched.ai });
    const file = writeReport(root, name, audit.timestamp, md);

    // Operator heads-up ONLY on a meaningful regression (gated notifier; never the client).
    const counts = summarize(findings);
    const change = summarizeDiff(delta, { locale });
    if (isMeaningfulChange(delta)) {
      await notify(root, `re-audit ${name}: ${change}`, counts, process.env, {});
      process.stderr.write(`[seo-engine] re-audit ALERT (meaningful change): ${change}\n`);
    } else {
      process.stderr.write(`[seo-engine] re-audit: ${delta.baseline ? 'baseline (first run)' : 'no meaningful change'} — no alert.\n`);
    }

    process.stdout.write(md + '\n');
    process.stderr.write(`[seo-engine] depth=${depth}\n`);
    process.stderr.write(`[seo-engine] report -> ${file}\n`);
    return;
  }

  fail(`unknown subcommand '${cmd}' (expected audit | reaudit | recommend | report-pdf | content-ideas | list | trend)`);
}

main().catch((err) => fail(String((err && err.stack) || err)));
