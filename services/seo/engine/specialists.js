// pi-system SEO engine — MULTI-SPECIALIST AI analysis layer (the "technical team").
// ===========================================================================
// Builds ON TOP of the existing engine (checks.{performance,security,seo,accessibility,
// best-practices} + deterministic findings + verdict) to make an audit feel like a
// trustworthy technical TEAM: a focused specialist per category PLUS a sales-angle
// analyst, then a LEAD-analyst synthesis that enforces ONE clear #1 priority.
//
// It REUSES the ai.js provider seam and is FULLY INERT without a key (every specialist
// AND the synthesis degrade to a deterministic template from the audit's OWN findings).
// It ENRICHES only — the deterministic report stands on its own. It is operator-only:
// it talks to no one, fetches nothing of its own (the only network is the shared,
// injectable AI chat), and SENDS nothing.
//
// HALLUCINATION HARDENING (the reason this is trustworthy):
//   * basedOn finding ids are computed BY US from the audit's REAL findings — a model
//     `basedOn` is only accepted when it maps to a real findingId/metric (verifyGrounding).
//   * Any model claim that does NOT map to a real finding/metric is kept as an
//     UNVERIFIED "general-suggestion", never presented as a detected issue.
//   * REAL NUMBERS ONLY: every quantitative figure must trace to audit.metrics/checks/
//     scores; guardNumbers() strips any numeric the model emits that is not traceable.
//
// Cost: each specialist is one AI call (5 technical + sales-angle = 6) plus one optional
// synthesis call — opt-in only (SEO_AI_PANEL=1 / --panel). A normal audit is unaffected.
// ===========================================================================

import { analyze, sortFindings } from './rules.js';
import { getAiProvider, parseAiJson } from './ai.js';

const PRIORITY_WEIGHT = { critical: 0, high: 1, medium: 2, low: 3 };
const SEVERITIES = ['critical', 'high', 'medium', 'low', 'ok'];
const EFFORTS = ['quick-win', 'medium', 'large'];
// For the SINGLE #1 priority + cross-cutting ordering: which category leads on a tie.
const CATEGORY_ORDER = ['security', 'performance', 'best-practices', 'seo', 'accessibility'];
const MAX_LEN = 600;

export const CONTENT_LOCALES = ['ar', 'en'];

const CAT = {
  ar: { performance: 'الأداء', security: 'الأمان', seo: 'تحسين محركات البحث', accessibility: 'سهولة الوصول', 'best-practices': 'أفضل الممارسات', sales: 'الزاوية البيعية' },
  en: { performance: 'Performance', security: 'Security', seo: 'SEO', accessibility: 'Accessibility', 'best-practices': 'Best practices', sales: 'Sales angle' },
};
const ROLE_AR = {
  'performance-analyst': 'محلّل الأداء', 'security-analyst': 'محلّل الأمان', 'seo-analyst': 'محلّل تحسين محركات البحث',
  'accessibility-analyst': 'محلّل سهولة الوصول', 'best-practices-analyst': 'محلّل أفضل الممارسات', 'sales-angle-analyst': 'محلّل الزاوية البيعية',
};

// Flat-check keys that belong to each non-nested category (perf/security are nested objects).
const FLAT_KEYS = {
  seo: ['title', 'metaDescription', 'h1', 'canonical', 'openGraph', 'twitterCard', 'structuredData', 'robotsTxt', 'sitemapXml', 'lang'],
  accessibility: ['imagesTotal', 'imagesMissingAlt', 'lang', 'viewport', 'h1'],
  'best-practices': ['https', 'viewport', 'dir'],
};

// Shared JSON-shape instruction appended to every technical specialist's system prompt.
const JSON_INSTR =
  ' Respond with STRICT JSON ONLY (no markdown, no text outside the JSON): ' +
  '{"severity":"critical|high|medium|low|ok","deepAnalysis":{"ar":"..","en":".."},' +
  '"businessImpact":{"ar":"..","en":".."},"prioritizedFixes":[{"fix":{"ar":"..","en":".."},' +
  '"effort":"quick-win|medium|large","impact":{"ar":"..","en":".."}}],' +
  '"claims":[{"text":"<a specific claim>","basedOn":"<a findingId or metric key you were given>"}]}. ' +
  'Arabic first. You may EXPLAIN or FRAME the real numbers you were given but you MUST NOT invent any ' +
  'figure (load time, size, score, count). In claims[].basedOn use ONLY a findingId or metric key from ' +
  'the input; do not invent ids. You advise the OPERATOR only; you never contact anyone.';

export const SPECIALISTS = [
  {
    id: 'performance-analyst', category: 'performance', role: 'Performance analyst',
    systemPrompt: 'You are a senior web-performance engineer reviewing ONE site\'s performance slice (its performance checks, the real timing/size metrics, and the deterministic performance findings).' + JSON_INSTR,
  },
  {
    id: 'security-analyst', category: 'security', role: 'Security analyst',
    systemPrompt: 'You are a senior web-security engineer reviewing ONE site\'s security slice (its security header checks and the deterministic security findings).' + JSON_INSTR,
  },
  {
    id: 'seo-analyst', category: 'seo', role: 'SEO analyst',
    systemPrompt: 'You are a senior SEO specialist reviewing ONE site\'s on-page SEO slice (title/meta/headings/canonical/structured-data checks and the deterministic SEO findings).' + JSON_INSTR,
  },
  {
    id: 'accessibility-analyst', category: 'accessibility', role: 'Accessibility analyst',
    systemPrompt: 'You are a senior accessibility specialist reviewing ONE site\'s accessibility slice (alt text, language, viewport, headings checks and the deterministic accessibility findings).' + JSON_INSTR,
  },
  {
    id: 'best-practices-analyst', category: 'best-practices', role: 'Best-practices analyst',
    systemPrompt: 'You are a senior web best-practices reviewer for ONE site\'s slice (HTTPS, responsive viewport, and the deterministic best-practice findings).' + JSON_INSTR,
  },
  {
    id: 'sales-angle-analyst', category: 'sales', role: 'Sales-angle analyst',
    systemPrompt:
      'You read ALL the technical results for ONE site (its category scores, overall verdict, finding counts, and the top findings) and produce OPERATOR SALES MATERIAL — never sent to anyone. ' +
      'In deepAnalysis give the SINGLE most compelling reason THIS site\'s owner should act now (plain Saudi-market business framing). In businessImpact give the concrete COST OF INACTION. ' +
      'In prioritizedFixes give ONE suggested offer angle the operator could pitch. Frame the real numbers; invent none.' + JSON_INSTR,
  },
];

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------
function normLocale(locale) {
  return String(locale || '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}
function nowIso(deps) {
  return new Date(deps && deps.now ? deps.now() : Date.now()).toISOString();
}
function clampText(value, max = MAX_LEN) {
  const t = String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
  return t.length > max ? t.slice(0, max - 1).trimEnd() + '…' : t;
}
function compactFinding(f) {
  return { id: f.id, priority: f.priority, category: f.category, title: f.title, recommendation: f.recommendation };
}
function findingsOf(audit) {
  const a = audit || {};
  return sortFindings(Array.isArray(a.findings) ? a.findings : analyze(a));
}
function countBy(findings) {
  const c = { critical: 0, high: 0, medium: 0, low: 0 };
  for (const f of findings) if (c[f.priority] !== undefined) c[f.priority] += 1;
  return c;
}
function severityOf(findings) {
  for (const s of ['critical', 'high', 'medium', 'low']) if (findings.some((f) => f.priority === s)) return s;
  return 'ok';
}
function effortFor(f) {
  const quick = new Set(['title-missing', 'meta-description-missing', 'h1-missing', 'viewport-missing', 'lang-missing', 'canonical-missing', 'images-not-lazy', 'images-missing-dimensions', 'open-graph-incomplete', 'robots-missing', 'twitter-card-incomplete']);
  if (f && quick.has(f.id)) return 'quick-win';
  switch (f && f.priority) {
    case 'critical': return 'large';
    case 'high': return 'medium';
    case 'medium': return 'medium';
    default: return 'quick-win';
  }
}
function pickFlat(checks, keys) {
  const out = {};
  for (const k of keys) if (checks && checks[k] !== undefined) out[k] = checks[k];
  return Object.keys(out).length ? out : null;
}

// Every number that is TRACEABLE to the audit (metrics/checks/scores/verdict + scale anchors).
export function collectAuditNumbers(audit) {
  const set = new Set([0, 100]);
  const walk = (v) => {
    if (v == null) return;
    if (typeof v === 'number' && Number.isFinite(v)) { set.add(v); return; }
    if (Array.isArray(v)) { v.forEach(walk); return; }
    if (typeof v === 'object') { for (const k of Object.keys(v)) walk(v[k]); }
  };
  const a = audit || {};
  walk(a.metrics); walk(a.checks); walk(a.scores); walk(a.status);
  if (a.verdict) walk(a.verdict.overall);
  return set;
}

// REAL NUMBERS ONLY: replace any QUANTITATIVE figure not traceable to the audit with [—].
// A bare small integer (an ordinal like "3 steps") passes; a decimal, a 2+ digit number, or
// any number with a unit is treated as a quantitative figure and must be traceable.
export function guardNumbers(text, allowed) {
  if (text == null) return text;
  return String(text).replace(/(\d[\d,]*(?:\.\d+)?)(\s*)(ms|s|kb|mb|gb|bytes?|px|%)?(?![a-z])/gi, (m, num, sp, unit) => {
    const val = parseFloat(String(num).replace(/,/g, ''));
    if (!Number.isFinite(val)) return m;
    const quantitative = !!unit || String(num).includes('.') || val >= 10;
    if (!quantitative) return m;
    if (allowed.has(val)) return m;
    return '[—]' + sp + (unit || '');
  });
}

// The real references a model claim is allowed to cite: every findingId + metric/score keys.
export function realRefs(audit) {
  const refs = new Set();
  for (const f of findingsOf(audit)) if (f && f.id) refs.add(String(f.id));
  const a = audit || {};
  for (const k of Object.keys(a.metrics || {})) refs.add(k);
  for (const k of Object.keys(a.scores || {})) refs.add(k);
  refs.add('overall');
  return refs;
}

// verifyGrounding(specialistOutput, audit) -> { grounded:[{claim,basedOn}], unverified:[claim] }.
// A claim is GROUNDED only when its basedOn maps to a REAL findingId/metric (validated here,
// never trusted from the model). Everything else is an unverified general-suggestion.
export function verifyGrounding(specialistOutput, audit) {
  const refs = realRefs(audit);
  const claims = Array.isArray(specialistOutput && specialistOutput.claims) ? specialistOutput.claims : [];
  const grounded = [];
  const unverified = [];
  for (const c of claims) {
    const text = typeof c === 'string' ? c : clampText(c && c.text, 240);
    const basedOn = (c && c.basedOn != null) ? String(c.basedOn).trim() : '';
    if (!text) continue;
    if (basedOn && refs.has(basedOn)) grounded.push({ claim: text, basedOn });
    else unverified.push(text);
  }
  return { grounded, unverified };
}

// The focused slice a specialist sees — ONLY its category context + real numbers.
function sliceForSpecialist(audit, spec) {
  const checks = audit.checks || {};
  const metrics = audit.metrics || {};
  const scores = audit.scores || {};
  const all = findingsOf(audit);

  if (spec.id === 'sales-angle-analyst') {
    return {
      mode: 'sales',
      name: audit.name || audit.url || null,
      scores,
      verdict: audit.verdict ? { overall: audit.verdict.overall, tier: audit.verdict.tier } : null,
      counts: countBy(all),
      topFindings: all.slice(0, 5).map(compactFinding),
    };
  }
  const cat = spec.category;
  const findings = all.filter((f) => f.category === cat).map(compactFinding);
  let catChecks = null;
  if (cat === 'performance') catChecks = checks.performance || null;
  else if (cat === 'security') catChecks = checks.security || null;
  else catChecks = pickFlat(checks, FLAT_KEYS[cat] || []);
  const m = cat === 'performance' ? { responseMs: metrics.responseMs, htmlBytes: metrics.htmlBytes, requests: metrics.requests } : {};
  return { mode: 'category', category: cat, score: scores[cat] ?? null, findings, checks: catChecks, metrics: m };
}

// ---------------------------------------------------------------------------
// Deterministic templates (the always-available fallback, grounded in real findings)
// ---------------------------------------------------------------------------
function bi(ar, en) { return { ar, en }; }

function templateSpecialist(spec, slice, audit) {
  const all = findingsOf(audit);
  if (spec.id === 'sales-angle-analyst') {
    const top = all[0];
    const c = slice.counts || { critical: 0, high: 0 };
    const overall = (slice.verdict && slice.verdict.overall != null) ? slice.verdict.overall : null;
    const reasonAr = top
      ? `أبرز سبب للتحرّك الآن: ${CAT.ar[top.category] || top.category} — ${top.title}.`
      : 'الموقع في حالة جيدة عمومًا؛ يمكن البناء عليه لتعزيز النتائج.';
    const reasonEn = top
      ? `The most compelling reason to act now: ${CAT.en[top.category] || top.category} — ${top.title}.`
      : 'The site is broadly in good shape; there is room to build on it.';
    return {
      id: spec.id, role: spec.role, category: 'sales',
      severity: severityOf(all),
      deepAnalysis: bi(reasonAr, reasonEn),
      businessImpact: bi(
        `تكلفة التأجيل: ${(c.critical || 0) + (c.high || 0)} ملاحظة عالية الأولوية تؤثر على الثقة والظهور${overall != null ? ` (التقييم العام ${overall}/100)` : ''}.`,
        `Cost of inaction: ${(c.critical || 0) + (c.high || 0)} high-priority issue(s) hurting trust and visibility${overall != null ? ` (overall ${overall}/100)` : ''}.`),
      prioritizedFixes: [{
        fix: bi('عرض حزمة معالجة لأهم الملاحظات مع تقرير واضح قبل/بعد.', 'Offer a fix package for the top issues with a clear before/after report.'),
        effort: 'medium',
        impact: bi('تحويل ملاحظات تقنية إلى عرض قيمة ملموس.', 'Turns technical findings into a concrete value pitch.'),
      }],
      grounded: all.slice(0, 3).map((f) => ({ claim: f.title, basedOn: f.id })),
      unverified: [],
      source: 'template',
      locales: CONTENT_LOCALES,
    };
  }

  const findings = slice.findings || [];
  const catAr = CAT.ar[slice.category] || slice.category;
  const catEn = CAT.en[slice.category] || slice.category;
  const sev = severityOf(findings.length ? findings : all.filter((f) => f.category === slice.category));
  const scoreStr = slice.score != null ? ` (${slice.score}/100)` : '';
  const deep = findings.length
    ? bi(`رصد محلّل ${catAr} ${findings.length} ملاحظة${scoreStr}؛ أبرزها: ${findings[0].title}.`,
         `The ${catEn} analyst found ${findings.length} issue(s)${scoreStr}; the top one: ${findings[0].title}.`)
    : bi(`لا ملاحظات جوهرية في ${catAr}${scoreStr} — حالة جيدة.`,
         `No material ${catEn} issues${scoreStr} — in good shape.`);
  const impact = bi(
    findings.length ? `قد تؤثر ملاحظات ${catAr} على تجربة الزوّار والنتائج إن تُركت دون معالجة.` : `استمرار جودة ${catAr} يدعم النتائج.`,
    findings.length ? `Unaddressed ${catEn} issues can hurt visitor experience and results.` : `Maintaining ${catEn} quality supports results.`);
  const fixes = findings.slice(0, 3).map((f) => ({
    fix: bi(f.title, f.title),
    effort: effortFor(f),
    impact: bi(f.recommendation || 'تحسين هذه النقطة.', f.recommendation || 'Improve this item.'),
  }));
  return {
    id: spec.id, role: spec.role, category: slice.category,
    severity: sev,
    deepAnalysis: deep,
    businessImpact: impact,
    prioritizedFixes: fixes,
    grounded: findings.map((f) => ({ claim: f.title, basedOn: f.id })),
    unverified: [],
    source: 'template',
    locales: CONTENT_LOCALES,
  };
}

// Validate + clamp + number-guard a model reply into the specialist output shape, per-slot
// falling back to the template. Grounding is recomputed from the REAL refs.
function buildAiOutput(spec, parsed, slice, audit, allowed, fb) {
  const g = (v) => clampText(guardNumbers(v, allowed));
  const pickBi = (obj, fbBi) => bi(g((obj && obj.ar)) || fbBi.ar, g((obj && obj.en)) || fbBi.en);

  const severity = SEVERITIES.includes(String(parsed.severity)) ? String(parsed.severity) : fb.severity;
  const deepAnalysis = pickBi(parsed.deepAnalysis, fb.deepAnalysis);
  const businessImpact = pickBi(parsed.businessImpact, fb.businessImpact);

  let fixes = [];
  if (Array.isArray(parsed.prioritizedFixes)) {
    for (const pf of parsed.prioritizedFixes.slice(0, 5)) {
      const fixBi = bi(g(pf && pf.fix && pf.fix.ar), g(pf && pf.fix && pf.fix.en));
      if (!fixBi.ar && !fixBi.en) continue;
      fixes.push({
        fix: bi(fixBi.ar || fixBi.en, fixBi.en || fixBi.ar),
        effort: EFFORTS.includes(String(pf && pf.effort)) ? String(pf.effort) : 'medium',
        impact: bi(g(pf && pf.impact && pf.impact.ar), g(pf && pf.impact && pf.impact.en)),
      });
    }
  }
  if (!fixes.length) fixes = fb.prioritizedFixes;

  const { grounded, unverified } = verifyGrounding(parsed, audit);
  return {
    id: spec.id, role: spec.role, category: fb.category,
    severity,
    deepAnalysis,
    businessImpact,
    prioritizedFixes: fixes,
    grounded: grounded.length ? grounded : fb.grounded, // always references real ids
    unverified,
    source: 'ai',
    locales: CONTENT_LOCALES,
  };
}

// Run ONE specialist. Degrades INDEPENDENTLY to its template on bad/empty/missing-key.
// Never throws; no network call when the provider is disabled.
async function runSpecialist(spec, audit, provider, allowed) {
  const slice = sliceForSpecialist(audit, spec);
  const fb = templateSpecialist(spec, slice, audit);
  if (!provider || !provider.enabled) return fb;
  let reply;
  try {
    reply = await provider.chat({ system: spec.systemPrompt, user: JSON.stringify(slice) });
  } catch (err) {
    const o = { ...fb }; o.error = String((err && err.message) || err); return o;
  }
  if (!reply || reply.ok !== true || !reply.text) {
    const o = { ...fb }; if (reply && reply.error) o.error = reply.error; return o;
  }
  const parsed = parseAiJson(reply.text);
  if (!parsed || typeof parsed !== 'object') return fb;
  return buildAiOutput(spec, parsed, slice, audit, allowed, fb);
}

// analyzeWithSpecialists(audit, env, deps) -> array of specialist outputs (one per SPECIALIST,
// in order). Each degrades independently; one failure never breaks the others.
export async function analyzeWithSpecialists(audit, env = {}, deps = {}) {
  const a = audit || {};
  const provider = getAiProvider(env, { fetchImpl: deps.aiFetchImpl });
  const allowed = collectAuditNumbers(a);
  const out = [];
  for (const spec of SPECIALISTS) {
    // sequential: bounded, deterministic order, and each is independent + best-effort.
    out.push(await runSpecialist(spec, a, provider, allowed)); // eslint-disable-line no-await-in-loop
  }
  return out;
}

// ---------------------------------------------------------------------------
// Lead-analyst synthesis — enforces ONE #1 priority + a unified, deduped plan.
// ---------------------------------------------------------------------------
function catRank(category) {
  const i = CATEGORY_ORDER.indexOf(category);
  return i === -1 ? CATEGORY_ORDER.length : i;
}
function normFix(s) { return String(s || '').toLowerCase().replace(/[^a-z0-9؀-ۿ]+/g, ' ').trim(); }

export function synthesizePanel(specialistOutputs, audit, env = {}, deps = {}) {
  const specs = Array.isArray(specialistOutputs) ? specialistOutputs : [];
  const all = findingsOf(audit);

  // --- ONE #1 priority: the single highest-priority REAL finding (never five "critical"s).
  const ranked = all.slice().sort((x, y) =>
    ((PRIORITY_WEIGHT[x.priority] ?? 9) - (PRIORITY_WEIGHT[y.priority] ?? 9))
    || (catRank(x.category) - catRank(y.category))
    || (x.id < y.id ? -1 : x.id > y.id ? 1 : 0));
  const lead = ranked[0] || null;
  const ownerRole = lead ? ((SPECIALISTS.find((s) => s.category === lead.category) || {}).role || 'Lead analyst') : 'Lead analyst';
  const topPriority = lead ? {
    category: lead.category,
    findingId: lead.id,
    title: lead.title,
    severity: lead.priority,
    role: ownerRole,
    reason: bi(
      `الأولوية رقم 1: ${CAT.ar[lead.category] || lead.category} — ${lead.title} (${({ critical: 'حرجة', high: 'عالية', medium: 'متوسطة', low: 'منخفضة' })[lead.priority] || lead.priority}).`,
      `#1 priority: ${CAT.en[lead.category] || lead.category} — ${lead.title} (${lead.priority}).`),
  } : null;

  // --- Unified, DEDUPED action plan across specialists (critical + quick-wins first).
  const sevWeight = { critical: 0, high: 1, medium: 2, low: 3, ok: 4 };
  const effWeight = { 'quick-win': 0, medium: 1, large: 2 };
  const seen = new Set();
  const plan = [];
  for (const sp of specs) {
    for (const pf of (sp.prioritizedFixes || [])) {
      const key = normFix(pf.fix && (pf.fix.en || pf.fix.ar));
      if (!key || seen.has(key)) continue;
      seen.add(key);
      plan.push({ fix: pf.fix, effort: pf.effort, impact: pf.impact, category: sp.category, severity: sp.severity || 'medium' });
    }
  }
  plan.sort((a, b) =>
    ((sevWeight[a.severity] ?? 5) - (sevWeight[b.severity] ?? 5))
    || ((effWeight[a.effort] ?? 3) - (effWeight[b.effort] ?? 3))
    || (catRank(a.category) - catRank(b.category)));

  // --- Cross-cutting risks: the top distinct high-severity categories (excluding the #1).
  const risks = [];
  for (const sp of specs) {
    if (sp.category === 'sales') continue;
    if (!(sp.severity === 'critical' || sp.severity === 'high')) continue;
    const f = all.find((x) => x.category === sp.category);
    if (lead && f && f.id === lead.findingId) continue;
    risks.push({ category: sp.category, title: f ? f.title : (CAT.en[sp.category] || sp.category), severity: sp.severity });
  }
  risks.sort((a, b) => ((sevWeight[a.severity] ?? 5) - (sevWeight[b.severity] ?? 5)) || (catRank(a.category) - catRank(b.category)));
  const topCrossCuttingRisks = risks.filter((r) => !lead || r.title !== lead.title).slice(0, 3);

  const criticalCount = specs.filter((s) => s.severity === 'critical').length;
  const overallNarrative = bi(
    topPriority
      ? `راجع الفريق ${specs.length} جانبًا. الأولوية القصوى: ${CAT.ar[topPriority.category] || topPriority.category} — ${topPriority.title}.`
      : 'راجع الفريق الموقع ولم يجد أولوية حرجة واحدة بارزة.',
    topPriority
      ? `The team reviewed ${specs.length} areas. The single top priority: ${CAT.en[topPriority.category] || topPriority.category} — ${topPriority.title}.`
      : 'The team reviewed the site and found no single critical priority.');

  return {
    topPriority,
    actionPlan: plan,
    topCrossCuttingRisks,
    overallNarrative,
    consistency: { criticalCount, singleTopPriority: true },
    source: 'merge',
  };
}

// runSpecialistPanel(audit, env, deps) -> { specialists, panel }. The bundle the report +
// alert consume. Inert without a key (templates, 0 network calls).
export async function runSpecialistPanel(audit, env = {}, deps = {}) {
  const specialists = await analyzeWithSpecialists(audit, env, deps);
  const panel = synthesizePanel(specialists, audit, env, deps);
  return { specialists, panel };
}

// ---------------------------------------------------------------------------
// Rendering (additive section + the one-line #1 risk for the operator alert)
// ---------------------------------------------------------------------------
export function panelTopRiskLine(bundle, locale) {
  const loc = normLocale(locale);
  const p = bundle && bundle.panel;
  if (!p || !p.topPriority) return '';
  return p.topPriority.reason[loc] || p.topPriority.reason.en || '';
}

export function renderPanelSection(bundle, opts = {}) {
  const loc = normLocale(opts.locale);
  const rtl = loc === 'ar';
  const specs = (bundle && bundle.specialists) || [];
  const panel = (bundle && bundle.panel) || {};
  const lines = [];
  lines.push(`## ${rtl ? 'تحليل فريق الخبراء' : 'Specialist panel'}`);
  lines.push('');
  lines.push(rtl
    ? '_تحليل متعدّد التخصصات بمساعدة الذكاء الاصطناعي — مادة للمشغّل، لا تُرسل لأحد._'
    : '_Multi-specialist AI analysis — operator material, sent to no one._');
  lines.push('');

  if (panel.topPriority) {
    lines.push(`**${rtl ? '⭐ الأولوية رقم 1' : '⭐ #1 priority'}:** ${panel.topPriority.reason[loc] || ''}`);
    lines.push('');
  }
  if (Array.isArray(panel.topCrossCuttingRisks) && panel.topCrossCuttingRisks.length) {
    lines.push(`**${rtl ? 'مخاطر متقاطعة' : 'Cross-cutting risks'}:**`);
    for (const r of panel.topCrossCuttingRisks) lines.push(`- ${CAT[loc][r.category] || r.category}: ${r.title} (${r.severity})`);
    lines.push('');
  }
  if (Array.isArray(panel.actionPlan) && panel.actionPlan.length) {
    lines.push(`**${rtl ? 'خطة العمل الموحّدة' : 'Unified action plan'}:**`);
    let i = 1;
    for (const a of panel.actionPlan.slice(0, 8)) {
      const fix = (a.fix && (a.fix[loc] || a.fix.en || a.fix.ar)) || '';
      lines.push(`${i}. ${fix} — ${a.effort}`);
      i += 1;
    }
    lines.push('');
  }
  if (panel.overallNarrative) { lines.push(panel.overallNarrative[loc] || ''); lines.push(''); }

  for (const sp of specs) {
    const role = rtl ? (ROLE_AR[sp.id] || sp.role) : sp.role;
    lines.push(`### ${role} — ${sp.severity}${sp.source === 'template' ? (rtl ? ' (نموذج)' : ' (template)') : ''}`);
    const da = sp.deepAnalysis && (sp.deepAnalysis[loc] || sp.deepAnalysis.en);
    if (da) lines.push(da);
    const imp = sp.businessImpact && (sp.businessImpact[loc] || sp.businessImpact.en);
    if (imp) { lines.push(''); lines.push(`*${rtl ? 'الأثر' : 'Impact'}:* ${imp}`); }
    if (Array.isArray(sp.prioritizedFixes) && sp.prioritizedFixes.length) {
      lines.push('');
      for (const pf of sp.prioritizedFixes) {
        const fix = pf.fix && (pf.fix[loc] || pf.fix.en || pf.fix.ar);
        if (fix) lines.push(`- ${fix} (${pf.effort})`);
      }
    }
    if (Array.isArray(sp.unverified) && sp.unverified.length) {
      lines.push('');
      lines.push(rtl ? '_اقتراحات عامة (ليست ملاحظات مرصودة):_' : '_General suggestions (not detected issues):_');
      for (const u of sp.unverified) lines.push(`- ${u}`);
    }
    lines.push('');
  }
  return lines.join('\n');
}
