#!/usr/bin/env node
// pi-system prospect organizer — CLI entrypoint (the container's ENTRYPOINT).
// ===========================================================================
// A self-hosted, operator-owned CRM-lite for a MANUAL client-acquisition workflow.
// It ORGANIZES a pipeline the operator enters by hand and ANALYZES a prospect's
// OWN public website by REUSING the services/seo engine (see analyze.js). It NEVER
// scrapes Google Maps / LinkedIn / any platform, and NEVER sends or bulk-sends any
// outreach — the operator contacts prospects MANUALLY. (See services/prospects/
// README.md for the full legal/ethical boundary; it is architectural, not a toggle.)
//
// Subcommands (scripts/prospects.sh drives these; they also run standalone):
//
//   add       --name <n> [--url <u>] [--status <s>] [--note <t>]
//             add a prospect the OPERATOR found and entered themselves.
//   list      [--status <s>] [--json]      list the pipeline.
//   show      --id <id> [--json]           show one prospect (notes, history, analysis).
//   update    --id <id> [--status <s>] [--followup <YYYY-MM-DD|clear>] [--url <u>] [--name <n>]
//             move status (validated transition), set/clear the follow-up date, edit fields.
//   note      --id <id> --text <t>         append a note (operator's own observation).
//   followups [--today <YYYY-MM-DD>] [--notify] [--json]
//             surface follow-ups DUE — a reminder to the OPERATOR (optionally pushed
//             to the operator's own channel). NEVER messages the prospect.
//   analyze   --id <id> [--engine probe|lighthouse] [--lh-json <f>] [--locale ar|en]
//             [--pdf] [--notify]
//             run the FULL pipeline on the prospect's OWN public site (run-analysis.js):
//             SSRF-guarded full audit (5 categories) -> verdict -> optional AI enrichment
//             -> Markdown (+ optional PDF with --pdf) report saved -> rich heads-up alert.
//             With --notify it goes END TO END as the automated flow: it ALSO pushes the
//             alert to the OPERATOR'S own channel (PROSPECTS_NOTIFY_CMD / Uptime-Kuma)
//             AND sets a follow-up reminder. The alert is ALWAYS operator-only — never
//             to the prospect. The operator still CONTACTS manually (template draft).
//   assist    --id <id>
//             OPTIONAL, env-gated AI decision assist (advisory only). On the prospect's
//             latest analysis + the operator's notes/status, suggest a lead-quality
//             score (0..100), a next action from a FIXED allowlist (research-more /
//             prepare-offer / follow-up / deprioritize) and a one-line rationale,
//             stored under ai_assist. Inert without an AI key; NEVER contacts anyone.
//   draft     --id <id> [--kind outreach|referral|content] [--locale ar|en]
//             OPTIONAL, env-gated AI-assisted DRAFTS built FROM the prospect's completed
//             audit: a value-first outreach message (references the 1-2 biggest issues), a
//             referral-request to an existing client, and an educational content snippet —
//             bilingual ar+en, stored under `drafts`. Inert (deterministic templates, no
//             network) without an AI key. DRAFTS ONLY — copy, edit, send yourself; never sends.
//   template  --kind intro|followup|audit-offer --id <id> [--lang en|ar]
//             print a DRAFT message to copy, personalize and send manually. Never sends.
//   status                                 terse overview of the pipeline.
//
// Data lives under --root (default $PROSPECTS_DATA_DIR or /data) — see store.js.
// This file is argument plumbing + I/O only; the engine modules do the work.
// ===========================================================================

import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

import {
  loadDb, saveDb, getProspect, listProspects, putProspect, uniqueId, writeReport, writeReportArtifact,
} from './store.js';
import {
  STATUSES, createProspect, setStatus, addNote, setFollowup, setFields, recordAssist, recordDrafts,
} from './pipeline.js';
import { dueFollowups, daysUntil, summarizeDue } from './followups.js';
import { analyzeProspect } from './analyze.js';
import { decisionAssist } from './decision-assist.js';
import { generateDrafts, normalizeDraftKind, normLocale as normDraftLocale } from './drafts.js';
import { runSpecialistPanel } from '../../seo/engine/specialists.js';
import { renderTemplate, draftBanner } from './templates.js';
import { runAnalysisPipeline } from './run-analysis.js';
import { notifyOperator, notifyAnalysis } from './notify.js';
import { renderReportPdf } from '../../seo/engine/pdf-export.js';

// Flags that LEGITIMATELY repeat on the CLI accumulate into an array. Every other
// flag is single-valued. Kept explicit so a typo can't silently collect somewhere.
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
  for (const k of REPEATABLE_FLAGS) if (out[k] === undefined) out[k] = [];
  return out;
}

function fail(msg) {
  process.stderr.write(`[prospects] error: ${msg}\n`);
  process.exit(1);
}

const out = (s) => process.stdout.write(s + '\n');
const todayIso = () => new Date().toISOString().slice(0, 10);

function fmtRow(r) {
  const fu = r.followup ? r.followup : '—';
  const an = r.lastAnalysis && r.lastAnalysis.scores
    ? `SEO ${r.lastAnalysis.scores.seo ?? '—'}/Perf ${r.lastAnalysis.scores.performance ?? '—'}`
    : '—';
  return `${String(r.id).padEnd(22)} ${String(r.status).padEnd(10)} ${String(fu).padEnd(12)} ${an.padEnd(20)} ${r.name}`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const cmd = args._[0] || 'list';
  const root = String(args.root || process.env.PROSPECTS_DATA_DIR || '/data');

  // ---- add ----------------------------------------------------------------
  if (cmd === 'add') {
    const name = String(args.name || '');
    if (!name.trim()) fail('add requires --name "<business name>"');
    const db = loadDb(root);
    const id = uniqueId(db, name);
    const now = new Date().toISOString();
    let rec;
    try {
      rec = createProspect(
        { name, url: args.url === true ? '' : args.url, status: args.status === true ? '' : args.status, note: args.note === true ? '' : args.note },
        { id, now },
      );
    } catch (e) { fail(String(e.message || e)); }
    putProspect(db, rec);
    saveDb(root, db);
    out(`Added prospect '${rec.id}' (${rec.name}) — status: ${rec.status}.`);
    if (!rec.url) out("Tip: add the prospect's public website with:  update " + rec.id + " --url https://...");
    return;
  }

  // ---- list ---------------------------------------------------------------
  if (cmd === 'list') {
    const db = loadDb(root);
    const filter = {};
    if (args.status && args.status !== true) filter.status = String(args.status);
    const rows = listProspects(db, filter);
    if (args.json) { out(JSON.stringify(rows, null, 2)); return; }
    if (rows.length === 0) { out('No prospects yet. Add one:  add --name "Business Name" --url https://...'); return; }
    out(`${'id'.padEnd(22)} ${'status'.padEnd(10)} ${'follow-up'.padEnd(12)} ${'last analysis'.padEnd(20)} name`);
    for (const r of rows) out(fmtRow(r));
    out(`\n${rows.length} prospect(s).`);
    return;
  }

  // ---- show ---------------------------------------------------------------
  if (cmd === 'show') {
    const id = String(args.id || '');
    const db = loadDb(root);
    const r = getProspect(db, id);
    if (!r) fail(`no prospect '${id}'. See: list`);
    if (args.json) { out(JSON.stringify(r, null, 2)); return; }
    out(`# ${r.name}  (${r.id})`);
    out(`status:     ${r.status}`);
    out(`website:    ${r.url || '—'}`);
    out(`follow-up:  ${r.followup || '—'}`);
    out(`created:    ${r.createdAt}`);
    out(`updated:    ${r.updatedAt}`);
    if (r.lastAnalysis) {
      const a = r.lastAnalysis;
      out(`analysis:   ${a.ts} (${a.engine}) — ${a.summary || ''}`);
      if (a.reportFile) out(`report:     ${a.reportFile}`);
    }
    if (r.ai_assist && r.ai_assist.enabled) {
      const ai = r.ai_assist;
      out(`ai assist:  [${ai.ts}] score ${ai.leadScore ?? '—'}/100 · next: ${ai.nextAction} (advisory) — ${ai.rationale}`);
    }
    if (r.drafts && Array.isArray(r.drafts.items) && r.drafts.items.length) {
      const d = r.drafts;
      const kinds = [...new Set(d.items.map((x) => x.kind))].join(', ');
      out(`drafts:     [${d.ts}] ${d.items.length} draft(s) (${kinds}) via ${d.source || '?'} — see:  draft ${r.id}  (operator-only)`);
    }
    if (r.notes && r.notes.length) {
      out('notes:');
      for (const n of r.notes) out(`  - [${n.ts}] ${n.text}`);
    }
    if (r.statusHistory && r.statusHistory.length) {
      out('history:');
      for (const h of r.statusHistory) out(`  - [${h.ts}] ${h.from || '∅'} -> ${h.to}`);
    }
    return;
  }

  // ---- update -------------------------------------------------------------
  if (cmd === 'update') {
    const id = String(args.id || '');
    const db = loadDb(root);
    let r = getProspect(db, id);
    if (!r) fail(`no prospect '${id}'. See: list`);
    const now = new Date().toISOString();
    let changed = false;
    try {
      if (args.name !== undefined || args.url !== undefined) {
        const f = {};
        if (args.name !== undefined) f.name = args.name === true ? '' : args.name;
        if (args.url !== undefined) f.url = args.url === true ? 'clear' : args.url;
        r = setFields(r, f, now); changed = true;
      }
      if (args.followup !== undefined) {
        r = setFollowup(r, args.followup === true ? 'clear' : args.followup, now); changed = true;
      }
      if (args.status !== undefined && args.status !== true) {
        r = setStatus(r, String(args.status), now); changed = true;
      }
    } catch (e) { fail(String(e.message || e)); }
    if (!changed) fail('update needs at least one of --status, --followup, --url, --name');
    putProspect(db, r);
    saveDb(root, db);
    out(`Updated '${r.id}' — status: ${r.status}, follow-up: ${r.followup || '—'}.`);
    return;
  }

  // ---- note ---------------------------------------------------------------
  if (cmd === 'note') {
    const id = String(args.id || '');
    const text = args.text === true ? '' : String(args.text || '');
    const db = loadDb(root);
    let r = getProspect(db, id);
    if (!r) fail(`no prospect '${id}'. See: list`);
    try { r = addNote(r, text, new Date().toISOString()); } catch (e) { fail(String(e.message || e)); }
    putProspect(db, r);
    saveDb(root, db);
    out(`Noted on '${r.id}' (${r.notes.length} note(s) total).`);
    return;
  }

  // ---- followups (reminder to the OPERATOR) -------------------------------
  if (cmd === 'followups') {
    const today = args.today && args.today !== true ? String(args.today) : todayIso();
    const db = loadDb(root);
    const due = dueFollowups(listProspects(db), today);
    if (args.json) { out(JSON.stringify(due, null, 2)); }
    else if (due.length === 0) { out(`No follow-ups due as of ${today}. ✅`); }
    else {
      out(`Follow-ups DUE as of ${today} — reach out to these YOURSELF:`);
      for (const r of due) {
        const d = daysUntil(r, today);
        const overdue = d < 0 ? ` (${-d}d overdue)` : d === 0 ? ' (today)' : '';
        out(`  - ${r.id.padEnd(22)} ${r.status.padEnd(10)} due ${r.followup}${overdue}  ${r.name}`);
      }
    }
    // Optional: push the summary to the OPERATOR'S own channel (never the prospect).
    if (args.notify) {
      const summary = summarizeDue(due, today);
      const spawnImpl = (cmdline, spawnArgs, stdin) => spawnSync(cmdline, spawnArgs, { input: stdin, shell: true });
      const res = await notifyOperator(root, summary, due.length, process.env, { spawnImpl });
      process.stderr.write(`[prospects] reminder -> ${res.wrote || '(none)'}${res.cmd ? ' + custom cmd' : ''}${res.kuma ? ' + kuma' : ''}\n`);
    }
    return;
  }

  // ---- analyze (the FULL automated pipeline — REUSES the services/seo engine) ----
  // `analyze <id>` runs: SSRF-guarded full audit (5 categories) -> verdict -> optional
  // AI enrichment -> Markdown report saved -> rich operator alert (local file). Adding
  // `--notify` runs it END TO END as the full automated flow: it ALSO pushes the alert
  // to the OPERATOR'S own channel (Telegram/Kuma) AND sets a follow-up reminder. `--pdf`
  // additionally exports a print-ready HTML (+ a PDF when a renderer is configured). The
  // ordering + seams live in run-analysis.js (pure, unit-tested); this block just binds
  // the real impls (store, notify, pdf) as injected seams.
  if (cmd === 'analyze') {
    const id = String(args.id || '');
    const db = loadDb(root);
    const r = getProspect(db, id);
    if (!r) fail(`no prospect '${id}'. See: list`);

    const engine = String(args.engine || 'probe');
    const notify = args.notify === true || String(args.notify) === 'true';
    const wantPdf = args.pdf === true || String(process.env.PROSPECTS_REPORT_PDF || '') === '1';
    const locale = String(args.locale && args.locale !== true ? args.locale : (process.env.PROSPECTS_REPORT_LOCALE || 'ar'));
    const followupDays = Number.parseInt(String(process.env.PROSPECTS_FOLLOWUP_DAYS || '3'), 10);
    const wantPanel = args.panel === true || String(args.panel) === 'true' || String(process.env.SEO_AI_PANEL || '') === '1';
    // --depth is the new explicit cost-vs-depth selector; --panel stays as a back-compat
    // alias for --depth deep. resolveDepth (called inside the pipeline) does the actual
    // precedence + validation so an unknown value throws a clear message.
    const depthArg = (args.depth && args.depth !== true) ? String(args.depth) : undefined;
    // --competitor <url> repeats; bounded by MAX_COMPETITORS (the engine enforces it).
    const competitorUrls = Array.isArray(args.competitor) ? args.competitor : [];

    let lhr = null;
    if (engine === 'lighthouse') {
      const lhPath = String(args['lh-json'] || '');
      if (!lhPath) fail("analyze --engine lighthouse requires --lh-json <path> (produce it via scripts/seo.sh)");
      try { lhr = JSON.parse(readFileSync(lhPath, 'utf8')); } catch (e) { fail(`could not read Lighthouse JSON: ${e.message || e}`); }
    }

    const spawnImpl = (cmdline, spawnArgs, stdin) => spawnSync(cmdline, spawnArgs, { input: stdin, shell: true });
    // Strip the channel vars so the seam only writes the local heads-up file when the
    // operator did NOT ask for the full --notify push (the alert is still saved locally).
    const noChannel = (env) => ({ ...env, PROSPECTS_NOTIFY_CMD: '', PROSPECTS_UPTIME_KUMA_PUSH_URL: '' });

    // Bind the real (impure) implementations as injected seams; run-analysis.js owns the order.
    const deps = {
      analyze: (prospect, env, d) => analyzeProspect(prospect, env, d),
      saveReport: (pid, ts, md) => writeReport(root, pid, ts, md),
      renderPdf: (md, o) => renderReportPdf(md, o, { env: process.env }),
      saveArtifact: (pid, ts, ext, data) => writeReportArtifact(root, pid, ts, ext, data),
      saveRecord: (record) => { putProspect(db, record); saveDb(root, db); },
      // The alert goes to the OPERATOR only. The local file is ALWAYS written; the channel
      // push (Telegram bot bridge / Uptime Kuma) fires only on the full --notify run.
      deliverAlert: (alert, push) => notifyAnalysis(root, alert, push ? process.env : noChannel(process.env), { spawnImpl }),
      // OPT-IN specialist panel (--panel / SEO_AI_PANEL). Inert without an AI key; reuses
      // the SEO engine. Each specialist + the synthesis is one AI call (see .env.example).
      runPanel: (audit) => runSpecialistPanel(audit, process.env, {}),
      now: () => Date.now(),
    };

    let res;
    try {
      res = await runAnalysisPipeline(r, process.env, {
        engine, lhr, locale, notify, pdf: wantPdf, followupDays,
        panel: wantPanel, depth: depthArg, competitorUrls,
      }, deps);
    } catch (e) { fail(String(e.message || e)); }

    out(res.report);
    process.stderr.write(`[prospects] depth=${res.depth}\n`);
    if (res.competitors && Array.isArray(res.competitors.competitors)) {
      const probed = res.competitors.competitors.length;
      const blocked = res.competitors.competitors.filter((x) => !x.ok).length;
      process.stderr.write(`[prospects] competitors: ${probed} probed, ${blocked} blocked/failed\n`);
    }
    process.stderr.write(`[prospects] ${res.summary}\n`);
    process.stderr.write(`[prospects] report -> ${res.reportFile}\n`);
    if (res.pdfFile) {
      process.stderr.write(`[prospects] pdf -> ${res.pdfFile}  (html -> ${res.htmlFile})\n`);
    } else if (wantPdf) {
      process.stderr.write(`[prospects] pdf: not produced — ${res.pdfReason}  (html -> ${res.htmlFile})\n`);
    }
    process.stderr.write('[prospects] Review/edit this report, then share it YOURSELF — this tool does not send it.\n');

    const a = res.alert || {};
    process.stderr.write(`[prospects] operator alert -> ${a.wrote || '(none)'}${a.cmd ? ' + custom cmd' : ''}${a.kuma ? ' + kuma' : ''} (operator-only; never the prospect)\n`);
    if (notify && res.followup) {
      process.stderr.write(`[prospects] follow-up reminder set for ${res.followup} — a nudge to YOU; see: followups\n`);
    } else if (!notify) {
      process.stderr.write('[prospects] Tip: re-run with --notify to push this alert to your channel AND set a follow-up reminder.\n');
    }

    if (process.env.AI_PROVIDER && process.env.AI_API_KEY) {
      process.stderr.write(`[prospects] Tip: AI is configured — get an advisory lead score + next step with:  assist --id ${r.id}\n`);
    }
    return;
  }

  // ---- assist (OPTIONAL, env-gated AI decision assist — advisory only) -----
  if (cmd === 'assist') {
    const id = String(args.id || '');
    const db = loadDb(root);
    let r = getProspect(db, id);
    if (!r) fail(`no prospect '${id}'. See: list`);
    if (!r.lastAnalysis) {
      fail(`'${id}' has no analysis yet — run:  analyze ${id}  first (the assist reads its audit verdict).`);
    }
    let assist;
    try {
      // Reuses the SEO provider seam; inert (no network) unless AI_PROVIDER + AI_API_KEY are set.
      assist = await decisionAssist(r, r.lastAnalysis, process.env, {});
    } catch (e) { fail(String(e.message || e)); }

    if (!assist.enabled) {
      out('AI decision assist is OFF — set AI_PROVIDER + AI_API_KEY in .env to enable it. Nothing changed.');
      out(assist.rationale);
      return;
    }

    r = recordAssist(r, assist, new Date().toISOString());
    putProspect(db, r);
    saveDb(root, db);

    out(`# AI decision assist — ${r.name} (${r.id})`);
    out('(advisory only — this NEVER contacts the prospect; outreach stays manual)');
    out(`lead score:   ${assist.leadScore ?? '—'}/100`);
    out(`next action:  ${assist.nextAction}${assist.actionFromModel === false ? '  (defaulted — the model returned an off-list value)' : ''}`);
    out(`rationale:    ${assist.rationale}`);
    out(`provider:     ${assist.provider}`);
    process.stderr.write('[prospects] This is advice for YOU. Decide and act yourself — the tool sends nothing.\n');
    return;
  }

  // ---- draft (OPTIONAL, AI-assisted copy-paste drafts — never sent) --------
  // Turns the prospect's COMPLETED audit into copy-paste-ready operator drafts (outreach /
  // referral-request / content-snippet), bilingual ar+en. Reuses the SEO AI provider seam:
  // inert (deterministic templates, no network) without an AI key. It DRAFTS only — the
  // operator copies, edits, and sends them HIMSELF; nothing here contacts anyone.
  if (cmd === 'draft') {
    const id = String(args.id || '');
    const db = loadDb(root);
    let r = getProspect(db, id);
    if (!r) fail(`no prospect '${id}'. See: list`);
    if (!r.lastAnalysis) {
      fail(`'${id}' has no analysis yet — run:  analyze ${id}  first (drafts are built FROM the audit).`);
    }
    // Optional filters for what to PRINT (all kinds/locales are always generated + stored).
    let wantKind = null;
    if (args.kind && args.kind !== true) {
      wantKind = normalizeDraftKind(args.kind);
      if (!wantKind) fail(`unknown --kind '${args.kind}' (one of: outreach | referral | content)`);
    }
    const wantLocale = (args.locale && args.locale !== true) ? normDraftLocale(args.locale) : null;

    // Reconstruct an audit view from the stored analysis — the verdict carries the top
    // findings (id/title/category/priority) the drafts reference. No new network probe.
    const audit = { name: r.name, url: r.url, scores: r.lastAnalysis.scores, verdict: r.lastAnalysis.verdict };
    let res;
    try {
      // Reuses the SEO provider seam; inert (no network) unless AI_PROVIDER + AI_API_KEY are set.
      res = await generateDrafts(r, audit, process.env, {});
    } catch (e) { fail(String(e.message || e)); }

    // Persist ALL drafts under prospect.drafts (an operator-only artifact; nothing sent).
    r = recordDrafts(r, { ts: res.ts, provider: res.provider, source: res.source, items: res.drafts }, new Date().toISOString());
    putProspect(db, r);
    saveDb(root, db);

    let shown = res.drafts;
    if (wantKind) shown = shown.filter((d) => d.kind === wantKind);
    if (wantLocale) shown = shown.filter((d) => d.locale === wantLocale);

    out(`# Drafts — ${r.name} (${r.id})`);
    out(res.enabled
      ? `(AI-assisted via ${res.provider} — operator-only: copy, personalize, and send these YOURSELF; nothing is sent)`
      : '(deterministic templates — set AI_PROVIDER + AI_API_KEY for AI-assisted drafts; operator-only, nothing is sent)');
    if (res.note) out(`_${res.note}_`);
    for (const d of shown) {
      out('');
      const basis = (d.basedOn && d.basedOn.length) ? `  (based on: ${d.basedOn.join(', ')})` : '';
      out(`## ${d.kind} · ${d.locale}${basis}`);
      if (d.subject) out(`Subject: ${d.subject}`);
      out('');
      out(d.body);
    }
    process.stderr.write('[prospects] Drafts are for YOU to copy, edit, and send yourself — this tool sends nothing.\n');
    return;
  }

  // ---- template (draft to copy; never sent) -------------------------------
  if (cmd === 'template') {
    const kind = String(args.kind || '');
    const lang = String(args.lang || 'en');
    const db = loadDb(root);
    let prospect = {};
    if (args.id && args.id !== true) {
      prospect = getProspect(db, String(args.id)) || {};
      if (!prospect.id) fail(`no prospect '${args.id}'. See: list`);
    }
    let text;
    try { text = renderTemplate(kind, { prospect, lang }); } catch (e) { fail(String(e.message || e)); }
    process.stderr.write(draftBanner(lang) + '\n');
    out(text);
    return;
  }

  // ---- status -------------------------------------------------------------
  if (cmd === 'status') {
    const db = loadDb(root);
    const all = listProspects(db);
    const today = todayIso();
    const due = dueFollowups(all, today);
    const byStatus = {};
    for (const s of STATUSES) byStatus[s] = 0;
    for (const r of all) if (byStatus[r.status] !== undefined) byStatus[r.status] += 1;
    out(`Prospects: ${all.length} total`);
    out('  ' + STATUSES.map((s) => `${s}: ${byStatus[s]}`).join('  ·  '));
    out(`Follow-ups due (${today}): ${due.length}`);
    return;
  }

  fail(`unknown subcommand '${cmd}' (expected add | list | show | update | note | followups | analyze | assist | draft | template | status)`);
}

main().catch((err) => fail(String((err && err.stack) || err)));
