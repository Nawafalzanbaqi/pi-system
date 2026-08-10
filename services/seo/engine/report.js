// pi-system SEO engine — the human-readable report renderer (pure).
// ===========================================================================
// renderReport(audit, findings, opts) -> a Markdown report string. Pure (no I/O,
// no clock): same inputs => same text, so it is unit-testable. The optional `ai`
// block (from ai.enrich) is appended only when AI enrichment ran; with AI off the
// report is the complete, deterministic rule-based output on its own.
// ===========================================================================

import { analyze, sortFindings, summarize } from './rules.js';
import { computeVerdict } from './verdict.js';
import { summarizeDiff } from './diff.js';
import { renderPanelSection } from './specialists.js';
import { depthLabel, isValidDepth } from './depth.js';
import { renderCompetitorSection } from './competitors.js';

const PRIORITY_LABEL = { critical: '🔴 CRITICAL', high: '🟠 HIGH', medium: '🟡 MEDIUM', low: '⚪ LOW' };
const CATEGORY_LABEL = {
  performance: 'Performance',
  accessibility: 'Accessibility',
  'best-practices': 'Best practices',
  seo: 'SEO',
};

function scoreLine(scores = {}) {
  return ['performance', 'accessibility', 'best-practices', 'seo']
    .map((c) => `${CATEGORY_LABEL[c]} ${Number.isFinite(scores[c]) ? scores[c] : '—'}/100`)
    .join('  ·  ');
}

export function renderReport(audit, findings, opts = {}) {
  const counts = summarize(findings);
  const lines = [];
  lines.push(`# SEO & site-quality report — ${audit.name}`);
  lines.push('');
  lines.push(`- **URL:** ${audit.url}`);
  lines.push(`- **Audited:** ${audit.timestamp}`);
  lines.push(`- **Engine:** ${audit.engine}${audit.engine === 'probe' ? ' (free, deterministic — no browser)' : ''}`);
  if (isValidDepth(audit.depth)) {
    // Pin the analysis depth on the report so a reader can tell which level produced
    // it at a glance (free triage vs single AI call vs full specialist panel).
    lines.push(`- **Depth:** ${depthLabel(audit.depth, 'en')}`);
  }
  lines.push(`- **Reachable:** ${audit.ok ? 'yes' : 'NO'}${audit.status ? ` (HTTP ${audit.status})` : ''}`);
  lines.push('');
  lines.push(`**Scores:** ${scoreLine(audit.scores)}`);
  lines.push('');
  lines.push(
    `**Findings:** ${findings.length} total — ` +
      `${counts.critical} critical, ${counts.high} high, ${counts.medium} medium, ${counts.low} low.`,
  );
  lines.push('');

  if (findings.length === 0) {
    lines.push('✅ No issues found by the rule-based checks. Nice.');
  } else {
    lines.push('## Recommendations (prioritised)');
    lines.push('');
    let i = 1;
    for (const x of findings) {
      lines.push(`### ${i}. ${PRIORITY_LABEL[x.priority] || x.priority} — ${x.title}`);
      lines.push(`*Category: ${CATEGORY_LABEL[x.category] || x.category} · id: \`${x.id}\`*`);
      lines.push('');
      lines.push(x.detail);
      lines.push('');
      lines.push(`**Fix:** ${x.recommendation}`);
      lines.push('');
      i += 1;
    }
  }

  // Optional AI enrichment — appended only when it actually ran. The deterministic
  // report above is complete on its own; this block only ADDS to it.
  const ai = opts.ai;
  if (ai && ai.enabled) {
    lines.push('## AI enrichment');
    lines.push('');
    lines.push(`_Provider: ${ai.provider} (optional, usage-billed on your own key)._`);
    lines.push('');

    // Client-facing executive summary, Arabic first (the platform is Arabic-first).
    const es = ai.executiveSummary;
    if (es && (es.ar || es.en)) {
      lines.push('### الملخص التنفيذي / Executive summary');
      lines.push('');
      if (es.ar) { lines.push(`> ${es.ar}`); lines.push('>'); }
      if (es.en) { lines.push(`> ${es.en}`); }
      lines.push('');
    }

    // Prioritised, deduplicated action plan with an effort estimate per item.
    if (Array.isArray(ai.actionPlan) && ai.actionPlan.length > 0) {
      lines.push('### Action plan (prioritised · effort-tagged)');
      lines.push('');
      lines.push('| # | Priority | Effort | Source | Recommendation |');
      lines.push('|---|----------|--------|--------|----------------|');
      let i = 1;
      for (const a of ai.actionPlan) {
        const prio = PRIORITY_LABEL[a.priority] || a.priority;
        const src = a.source === 'ai' ? 'AI' : 'rule';
        const rec = String(a.recommendation || a.title || '').replace(/\|/g, '\\|').replace(/\n+/g, ' ');
        lines.push(`| ${i} | ${prio} | ${a.effort} | ${src} | **${String(a.title || '').replace(/\|/g, '\\|')}** — ${rec} |`);
        i += 1;
      }
      lines.push('');
    }

    // Surface only operational notes/errors from the raw reply (never the JSON blob).
    if (ai.error) { lines.push(`_AI enrichment error: ${ai.error} (the rule-based report above is unaffected)._`); lines.push(''); }
    for (const s of (ai.suggestions || [])) {
      if (s && s.note) { lines.push(`_${s.note}_`); lines.push(''); }
    }
  } else {
    lines.push('---');
    lines.push(
      '_AI enrichment is OFF (the default). The report above is fully deterministic ' +
        'and needs no API key. To add deeper suggestions, set `AI_PROVIDER` + `AI_API_KEY` ' +
        'in `.env` — usage is billed on your own account. See docs/README.md “SEO & site quality”._',
    );
  }
  lines.push('');
  return lines.join('\n');
}

// A one-line summary for the notifier / Telegram (no Markdown).
export function renderSummary(audit, findings) {
  const counts = summarize(findings);
  const s = audit.scores || {};
  return (
    `SEO ${audit.name}: SEO ${s.seo ?? '—'} · Perf ${s.performance ?? '—'} · ` +
    `A11y ${s.accessibility ?? '—'} · BP ${s['best-practices'] ?? '—'} | ` +
    `${counts.critical} crit, ${counts.high} high, ${counts.medium} med, ${counts.low} low`
  );
}

// ===========================================================================
// buildProspectReport(audit, { locale, ai }) -> a clean, client-facing Markdown report.
// ===========================================================================
// The SALES-ANGLE artifact (the prospect organizer's "here's what I noticed" doc):
// it folds ONE audit into a tidy, well-structured report a non-technical client can
// read at a glance — a site/client header, the overall verdict + tier, the five
// category scores as a simple table, the top prioritised findings (critical-first)
// with plain recommendations, the AI executive summary (only when AI ran), and a footer.
//
// BILINGUAL + RTL-FIRST: locale 'ar' (the platform default) renders the report in
// Arabic wrapped in <div dir="rtl"> so the prose flows right-to-left; locale 'en'
// renders the SAME structure in English, left-to-right. Anything that is not English
// degrades to Arabic — the platform's Arabic-first convention. Only the framing
// (headings, labels, tier words, verdict sentence, footer) is localized; the individual
// finding titles/recommendations are the SEO engine's own deterministic text.
//
// PURE + DETERMINISTIC: no I/O, no clock. It reads audit.verdict (or recomputes it via
// computeVerdict when absent) and audit.findings (or derives them via analyze), so the
// SAME audit always yields the SAME report text. The store layer (store.writeReport)
// is what persists it under data/seo/reports/.
//
// The AI executive summary comes from opts.ai (or audit.ai) — the { enabled,
// executiveSummary:{ar,en} } block returned by ai.enrich — and is shown ONLY when AI
// actually ran. With AI off, the localized verdict sentence still summarises the site,
// so the report stands on its own exactly like the deterministic rules path.
// ===========================================================================

// Tier + priority + category words, per locale. Arabic first (the platform default).
const TIER_WORD = {
  ar: { excellent: 'ممتاز', good: 'جيد', fair: 'مقبول', poor: 'ضعيف' },
  en: { excellent: 'excellent', good: 'good', fair: 'fair', poor: 'poor' },
};
const PRIORITY_WORD = {
  ar: { critical: '🔴 حرجة', high: '🟠 عالية', medium: '🟡 متوسطة', low: '⚪ منخفضة' },
  en: { critical: '🔴 CRITICAL', high: '🟠 HIGH', medium: '🟡 MEDIUM', low: '⚪ LOW' },
};
const CATEGORY_WORD = {
  ar: {
    seo: 'تحسين محركات البحث', performance: 'الأداء', security: 'الأمان',
    'best-practices': 'أفضل الممارسات', accessibility: 'سهولة الوصول',
  },
  en: {
    seo: 'SEO', performance: 'Performance', security: 'Security',
    'best-practices': 'Best practices', accessibility: 'Accessibility',
  },
};
// The five categories, in client-facing importance order, for the scores table.
const PROSPECT_CATEGORIES = ['seo', 'performance', 'security', 'best-practices', 'accessibility'];
// Keep the prospect report tight — show the highest-priority findings, count the rest.
const MAX_PROSPECT_FINDINGS = 8;

// Arabic for anything that is not explicitly English (RTL-first default).
function normLocale(locale) {
  return String(locale || '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}

// Same cut-offs as verdict.js TIERS, applied to a single category score; null if absent.
function tierForScore(n) {
  if (!Number.isFinite(n)) return null;
  if (n >= 90) return 'excellent';
  if (n >= 75) return 'good';
  if (n >= 50) return 'fair';
  return 'poor';
}

// One localized, plain-language verdict line (the sales hook), Arabic-first.
function verdictSentence(loc, audit, verdict, findings) {
  const overall = verdict.overall;
  if (audit && audit.ok === false) {
    return loc === 'ar'
      ? 'الموقع غير متاح حاليًا — إعادته إلى الإنترنت هي الأولوية القصوى قبل أي تحسين آخر.'
      : 'The site is unreachable right now — getting it back online is the most urgent fix.';
  }
  if (findings.length === 0) {
    return loc === 'ar'
      ? `لا توجد ملاحظات جوهرية — الموقع في حالة قوية ويحقق ${overall}/100.`
      : `No major issues found — the site is in strong shape at ${overall}/100.`;
  }
  const top = findings[0];
  const cat = CATEGORY_WORD[loc][top.category] || top.category;
  const prio = (loc === 'ar'
    ? { critical: 'حرجة', high: 'عالية', medium: 'متوسطة', low: 'منخفضة' }
    : { critical: 'critical', high: 'high', medium: 'medium', low: 'low' })[top.priority] || top.priority;
  return loc === 'ar'
    ? `أكبر فرصة للتحسين: ${top.title} — ملاحظة بأولوية ${prio} ضمن فئة ${cat}.`
    : `Biggest opportunity: ${top.title} — a ${prio}-priority ${cat} fix.`;
}

// "Changes since last audit" — the re-audit MONITORING section. Rendered ONLY when a
// diff against a PREVIOUS audit exists (strictly additive; absent on a first/baseline
// run). Leads with the bilingual summarizeDiff paragraph, then the overall move + the
// resolved/new/persisting counts, then names the NEW critical/high findings.
function changesLines(loc, rtl, diff) {
  const out = [];
  if (!diff || diff.baseline) return out;
  const arrow = (dir) => (dir === 'up' ? '▲' : dir === 'down' ? '▼' : '▬');
  out.push(`## ${rtl ? 'التغييرات منذ آخر فحص' : 'Changes since last audit'}`);
  out.push('');
  out.push(summarizeDiff(diff, { locale: loc }));
  out.push('');
  const o = diff.overall || {};
  if (Number.isFinite(o.previous) && Number.isFinite(o.current)) {
    out.push(`- **${rtl ? 'النتيجة الإجمالية' : 'Overall'}:** ${o.previous} → ${o.current} ${arrow(o.direction)}`);
  }
  const f = diff.findings || { new: [], resolved: [], persisting: [] };
  out.push(rtl
    ? `- **ملاحظات جديدة:** ${f.new.length} · **تم حلّها:** ${f.resolved.length} · **مستمرة:** ${f.persisting.length}`
    : `- **New issues:** ${f.new.length} · **Resolved:** ${f.resolved.length} · **Persisting:** ${f.persisting.length}`);
  const flagged = (f.new || []).filter((x) => x.priority === 'critical' || x.priority === 'high');
  if (flagged.length) {
    out.push('');
    out.push(`**${rtl ? 'ملاحظات جديدة عالية الأهمية' : 'New high-priority issues'}:**`);
    for (const x of flagged) {
      const prio = PRIORITY_WORD[loc][x.priority] || x.priority;
      const cat = CATEGORY_WORD[loc][x.category] || x.category;
      out.push(`- ${prio} — ${x.title} (${cat})`);
    }
  }
  out.push('');
  return out;
}

export function buildProspectReport(audit, opts = {}) {
  const a = audit || {};
  const loc = normLocale(opts.locale);
  const rtl = loc === 'ar';
  // Re-audit diff (optional): explicit opts.diff wins, else a pre-attached audit.diff.
  const diff = opts.diff || a.diff || null;

  // Self-contained: honour a pre-attached verdict/findings, else derive them (pure).
  const verdict = (a.verdict && typeof a.verdict === 'object') ? a.verdict : computeVerdict(a);
  const findings = sortFindings(Array.isArray(a.findings) ? a.findings : analyze(a));
  const counts = summarize(findings);
  const scores = a.scores || {};
  const tier = verdict.tier || tierForScore(verdict.overall) || 'poor';
  const name = a.name || a.url || (rtl ? 'الموقع' : 'the site');

  const lines = [];
  // RTL wrapper so the Arabic prose flows right-to-left in any markdown renderer;
  // blank lines keep the block elements (headings, table, lists) rendering inside it.
  if (rtl) { lines.push('<div dir="rtl">'); lines.push(''); }

  // --- Client / site header -------------------------------------------------
  lines.push(`# ${rtl ? 'تقرير تحسين محركات البحث وجودة الموقع' : 'SEO & site-quality report'} — ${name}`);
  lines.push('');
  lines.push(`- **${rtl ? 'الموقع' : 'Site'}:** ${name}`);
  lines.push(`- **${rtl ? 'الرابط' : 'URL'}:** ${a.url || '—'}`);
  lines.push(`- **${rtl ? 'تاريخ الفحص' : 'Audited'}:** ${a.timestamp || '—'}`);
  const engineNote = a.engine === 'probe'
    ? (rtl ? ' (مجاني، حتمي — بدون متصفح)' : ' (free, deterministic — no browser)') : '';
  lines.push(`- **${rtl ? 'المحرك' : 'Engine'}:** ${a.engine || '—'}${engineNote}`);
  if (isValidDepth(a.depth)) {
    // Pin the analysis depth (localized) so the recipient can tell which level
    // produced this report: free triage, a single AI call, or the specialist panel.
    lines.push(`- **${rtl ? 'مستوى التحليل' : 'Depth'}:** ${depthLabel(a.depth, loc)}`);
  }
  const statusPart = a.status ? ` (HTTP ${a.status})` : '';
  const reach = a.ok === false ? (rtl ? 'غير متاح' : 'NO') : (rtl ? 'متاح' : 'yes');
  lines.push(`- **${rtl ? 'الحالة' : 'Reachable'}:** ${reach}${statusPart}`);
  lines.push('');

  // --- Overall verdict + tier ----------------------------------------------
  lines.push(`## ${rtl ? 'التقييم العام' : 'Overall verdict'}`);
  lines.push('');
  lines.push(`**${rtl ? 'النتيجة الإجمالية' : 'Overall score'}:** ${verdict.overall}/100 — ${TIER_WORD[loc][tier] || tier}`);
  lines.push('');
  lines.push(verdictSentence(loc, a, verdict, findings));
  lines.push('');

  // --- Changes since last audit (only when a previous audit exists) ---------
  for (const l of changesLines(loc, rtl, diff)) lines.push(l);

  // --- The five category scores, as a simple table -------------------------
  lines.push(`## ${rtl ? 'نتائج الفئات' : 'Category scores'}`);
  lines.push('');
  lines.push(rtl ? '| الفئة | النتيجة | التقييم |' : '| Category | Score | Rating |');
  lines.push('|---|---|---|');
  for (const cat of PROSPECT_CATEGORIES) {
    const v = scores[cat];
    const scoreCell = Number.isFinite(v) ? `${v}/100` : '—';
    const rt = tierForScore(v);
    const ratingCell = rt ? (TIER_WORD[loc][rt] || rt) : '—';
    lines.push(`| ${CATEGORY_WORD[loc][cat]} | ${scoreCell} | ${ratingCell} |`);
  }
  lines.push('');

  // --- Top prioritised findings (critical-first) ---------------------------
  lines.push(`## ${rtl ? 'التوصيات حسب الأولوية' : 'Recommendations (prioritised)'}`);
  lines.push('');
  if (findings.length === 0) {
    lines.push(rtl
      ? '✅ لم تُرصد أي ملاحظات من الفحوصات الآلية — الموقع في حالة جيدة.'
      : '✅ No issues found by the automated checks — the site is in good shape.');
    lines.push('');
  } else {
    lines.push(rtl
      ? `**عدد الملاحظات:** ${findings.length} — ${counts.critical} حرجة، ${counts.high} عالية، ${counts.medium} متوسطة، ${counts.low} منخفضة.`
      : `**Findings:** ${findings.length} — ${counts.critical} critical, ${counts.high} high, ${counts.medium} medium, ${counts.low} low.`);
    lines.push('');
    const shown = findings.slice(0, MAX_PROSPECT_FINDINGS);
    let i = 1;
    for (const x of shown) {
      const prio = PRIORITY_WORD[loc][x.priority] || x.priority;
      const cat = CATEGORY_WORD[loc][x.category] || x.category;
      lines.push(`### ${i}. ${prio} — ${x.title}`);
      lines.push(`*${rtl ? 'الفئة' : 'Category'}: ${cat}*`);
      lines.push('');
      lines.push(`> ${x.recommendation}`);
      lines.push('');
      i += 1;
    }
    const more = findings.length - shown.length;
    if (more > 0) {
      lines.push(rtl
        ? `_و${more} ملاحظة إضافية في الفحص الكامل._`
        : `_…and ${more} more finding(s) in the full audit._`);
      lines.push('');
    }
  }

  // --- AI executive summary (only when AI enrichment actually ran) ----------
  const ai = opts.ai || a.ai;
  const es = (ai && ai.enabled && ai.executiveSummary) ? ai.executiveSummary : null;
  if (es && (es[loc] || es.ar || es.en)) {
    lines.push(`## ${rtl ? 'الملخص التنفيذي' : 'Executive summary'}`);
    lines.push('');
    lines.push(`> ${es[loc] || es.ar || es.en}`);
    lines.push('');
  }

  // --- Specialist panel (additive; only when a panel bundle is supplied) ----
  const panel = opts.panel || a.panel || null;
  if (panel && (Array.isArray(panel.specialists) ? panel.specialists.length : panel.panel)) {
    lines.push(renderPanelSection(panel, { locale: loc }));
    lines.push('');
  }

  // --- Competitor comparison (additive; only when a comparison is supplied) -
  // opts.competitors wins; else a pre-attached audit.competitors (the store
  // round-trip). Empty/missing data renders nothing — strictly additive.
  const comparison = opts.competitors || a.competitors || null;
  if (comparison && Array.isArray(comparison.competitors) && comparison.competitors.length) {
    const section = renderCompetitorSection(comparison, { locale: loc });
    if (section) {
      lines.push(section);
      lines.push('');
    }
  }

  // --- Footer ---------------------------------------------------------------
  lines.push('---');
  lines.push(rtl
    ? '_أُنشئ هذا التقرير تلقائيًا بواسطة محرك pi-system لتحسين محركات البحث وجودة المواقع — راجِعه وعدِّله قبل مشاركته._'
    : '_Generated automatically by the pi-system SEO & site-quality engine — review and edit before sharing._');
  lines.push('');
  if (rtl) { lines.push('</div>'); lines.push(''); }

  return lines.join('\n');
}
