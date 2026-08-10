// pi-system SEO engine — CONTENT-IDEA engine (mine your OWN audit history).
// ===========================================================================
// Turns the operator's accumulated audit history into DATA-BACKED content topics to
// attract inbound clients. It reads ONLY the operator's existing LOCAL stores (the
// SEO audits JSONL +, best-effort, the prospects store) — it scrapes NOTHING and
// sends NOTHING. Same architectural boundary as drafts.js / decision-assist.js: the
// no-send/no-scrape tests must stay green.
//
//   analyzeIssuePatterns(audits) -> PURE. Aggregates an array of stored audits into
//     ranked recurring findings (most-common-first), counts only:
//       [ { findingId, category, title, priority, occurrences, sites, pctOfSites } ]
//     No AI, no I/O — fully unit-testable against fixture audit arrays.
//
//   auditsFromProspectsDb(db) -> PURE. Maps a prospects store document
//     ({ prospects: { id: record } }) to audit-like objects (using each record's stored
//     lastAnalysis verdict), so the SAME aggregator can fold the prospects store in. No I/O.
//
//   generateContentIdeas(patterns, env, deps) -> gated AI step. Turns the top patterns
//     into 3-5 bilingual (ar-first/en) content topic ideas:
//       [ { title, angle, basedOnPattern, targetAudience, locale } ]
//     framed as EDUCATIONAL/inbound, never about a named client. INERT without a key:
//     no request is built, NO network call is made, and the result is deterministic
//     templates derived from the patterns. Validated/clamped; a garbled/empty/throwing
//     reply degrades to templates — it never throws and never calls the network keyless.
//     basedOnPattern is set by US from the real aggregated patterns, never the model.
// ===========================================================================

import { analyze } from './rules.js';
import { getAiProvider, parseAiJson } from './ai.js';

const PRIORITY_WEIGHT = { critical: 0, high: 1, medium: 2, low: 3 };
const MAX_TOPICS = 5;
const MAX_TITLE = 140;
const MAX_ANGLE = 320;
const MAX_AUDIENCE = 120;

export const CONTENT_LOCALES = ['ar', 'en'];

// Localized category words + a sensible target audience per category (Arabic first).
const CAT = {
  ar: {
    performance: 'سرعة الموقع', security: 'أمان الموقع', seo: 'الظهور في محركات البحث',
    accessibility: 'سهولة الوصول للجميع', 'best-practices': 'الجودة التقنية للموقع',
  },
  en: {
    performance: 'page speed', security: 'site security', seo: 'search visibility',
    accessibility: 'accessibility', 'best-practices': 'technical quality',
  },
};
const AUDIENCE = {
  ar: {
    performance: 'أصحاب المتاجر والمواقع الذين يهمّهم سرعة التصفّح على الجوال',
    security: 'الأنشطة التي تتعامل مع بيانات العملاء',
    seo: 'أصحاب الأعمال الباحثون عن زيارات أكثر من محركات البحث',
    accessibility: 'الأنشطة التي تريد الوصول لأكبر شريحة من العملاء',
    'best-practices': 'أصحاب الأعمال الصغيرة والمتوسطة',
  },
  en: {
    performance: 'shop and site owners who care about mobile load speed',
    security: 'businesses that handle customer data',
    seo: 'business owners who want more traffic from search',
    accessibility: 'businesses that want to reach the widest possible audience',
    'best-practices': 'small and medium business owners',
  },
};

// When there is NO audit history yet, fall back to a few evergreen seed topics so the
// command still helps. These are clearly NOT data-backed (synthetic ids).
const GENERIC_SEEDS = [
  { findingId: 'general-performance', category: 'performance', title: 'Website speed' },
  { findingId: 'general-seo', category: 'seo', title: 'Search visibility' },
  { findingId: 'general-security', category: 'security', title: 'Website security' },
];

function nowIso(deps) {
  return new Date(deps && deps.now ? deps.now() : Date.now()).toISOString();
}
function normLocale(locale) {
  return String(locale || '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}
function oneLine(value, max) {
  const t = String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
  return t.length > max ? t.slice(0, max - 1).trimEnd() + '…' : t;
}

// --- (1) PURE aggregator ----------------------------------------------------
// Honours a pre-attached audit.findings (controlled fixtures + prospects-derived audits),
// else derives them from the SAME deterministic engine (rules.analyze). Counts each
// finding once per audit; tracks the distinct sites (audit.name) it appears on.
export function analyzeIssuePatterns(audits) {
  const list = Array.isArray(audits) ? audits : [];
  const sites = new Set();
  const byId = new Map();

  for (const a of list) {
    if (!a || typeof a !== 'object') continue;
    const site = a.name || a.url || null;
    if (site) sites.add(site);
    // Use an explicitly-attached findings array AS-IS (even when empty — that means a
    // clean audit); only DERIVE via the deterministic engine when none was attached (the
    // shape real stored SEO audits have — they carry no findings field).
    const findings = Array.isArray(a.findings) ? a.findings : analyze(a);
    const seen = new Set(); // count a finding once per audit
    for (const f of findings) {
      if (!f || !f.id || seen.has(f.id)) continue;
      seen.add(f.id);
      let rec = byId.get(f.id);
      if (!rec) {
        rec = {
          findingId: f.id,
          category: f.category || 'seo',
          title: f.title || f.id,
          priority: f.priority || 'medium',
          occurrences: 0,
          _sites: new Set(),
        };
        byId.set(f.id, rec);
      }
      rec.occurrences += 1;
      if (site) rec._sites.add(site);
    }
  }

  const totalSites = sites.size;
  const out = [...byId.values()].map((r) => ({
    findingId: r.findingId,
    category: r.category,
    title: r.title,
    priority: r.priority,
    occurrences: r.occurrences,
    sites: r._sites.size,
    pctOfSites: totalSites ? Math.round((100 * r._sites.size) / totalSites) : 0,
  }));

  // Most-common-first, then by reach, then severity, then id (stable + deterministic).
  out.sort((a, b) =>
    (b.occurrences - a.occurrences)
    || (b.sites - a.sites)
    || ((PRIORITY_WEIGHT[a.priority] ?? 9) - (PRIORITY_WEIGHT[b.priority] ?? 9))
    || (a.findingId < b.findingId ? -1 : a.findingId > b.findingId ? 1 : 0));
  return out;
}

// --- PURE: prospects store -> audit-like objects ----------------------------
// Reads each prospect's stored lastAnalysis verdict.topFindings (the only finding data
// the prospects store keeps) so the aggregator can fold the prospects store in. No I/O.
export function auditsFromProspectsDb(db) {
  const recs = (db && db.prospects && typeof db.prospects === 'object') ? Object.values(db.prospects) : [];
  const out = [];
  for (const r of recs) {
    const la = r && r.lastAnalysis;
    if (!la) continue;
    const findings = (la.verdict && Array.isArray(la.verdict.topFindings)) ? la.verdict.topFindings : [];
    if (!findings.length) continue;
    out.push({ name: r.id || r.url || null, url: la.url || r.url || null, scores: la.scores || null, verdict: la.verdict || null, findings });
  }
  return out;
}

// --- (2) Deterministic, bilingual TEMPLATE ideas (always available) ---------
function templateIdea(pattern, loc) {
  const cat = CAT[loc][pattern.category] || pattern.category;
  const audience = AUDIENCE[loc][pattern.category] || (loc === 'ar' ? 'أصحاب الأعمال الصغيرة والمتوسطة' : 'small and medium business owners');
  if (loc === 'ar') {
    return {
      title: `لماذا تهمّ ${cat} لموقع نشاطك؟`,
      angle: `شرح مبسّط لكيفية تأثير ${cat} على تجربة الزوّار والمبيعات، مع خطوات عملية للتحسين — مبني على ملاحظات متكرّرة في مواقع فعلية دون ذكر أي عميل.`,
      targetAudience: audience,
    };
  }
  return {
    title: `Why ${cat} matters for your business website`,
    angle: `A plain-language explainer on how ${cat} affects visitor experience and sales, with practical fixes — drawn from a recurring pattern across real sites, naming no client.`,
    targetAudience: audience,
  };
}

// The compact, no-network context the model sees (the ranked patterns only).
export function buildIdeaContext(patterns) {
  return {
    topPatterns: (patterns || []).map((p) => ({
      findingId: p.findingId, category: p.category, title: p.title,
      occurrences: p.occurrences, pctOfSites: p.pctOfSites,
    })),
    locales: CONTENT_LOCALES,
  };
}

const IDEAS_SYSTEM_PROMPT =
  'You are a content strategist for a SOLO freelance web-services operator in Saudi Arabia. ' +
  'You are given the operator\'s OWN recurring website-audit issue patterns (each with a findingId, ' +
  'category, title, and how often it occurs across their audited sites). Propose EDUCATIONAL, ' +
  'inbound-marketing content TOPIC ideas that teach the lesson behind these recurring issues to ' +
  'attract new clients. The topics must be GENERAL and educational — NEVER about any specific or ' +
  'named client, and never reveal client data. For EACH provided findingId, write one idea in Arabic ' +
  '(first) AND English. Respond with STRICT JSON ONLY (no markdown, no text outside the JSON), an ' +
  'object keyed by the findingId, of exactly this shape: ' +
  '{"<findingId>":{"ar":{"title":"..","angle":"<one or two sentences>","targetAudience":".."},' +
  '"en":{"title":"..","angle":"..","targetAudience":".."}}}. ' +
  'Keep titles short and natural, angles to one or two sentences, Arabic first. Do not invent facts ' +
  'beyond the provided patterns.';

// Map a parsed reply onto our seed findingIds. Returns null when nothing usable is present.
function normalizeAiIdeas(parsed, seeds) {
  if (!parsed || typeof parsed !== 'object') return null;
  const out = {};
  let usable = false;
  for (const s of seeds) {
    const v = parsed[s.findingId];
    if (v && typeof v === 'object' && (v.ar || v.en)) { out[s.findingId] = v; usable = true; }
  }
  return usable ? out : null;
}

function aiSlot(aiKind, locale) {
  if (!aiKind || typeof aiKind !== 'object') return {};
  const v = aiKind[locale];
  return (v && typeof v === 'object') ? v : {};
}

// Build all ideas: one per seed pattern per locale. AI text is used PER SLOT when present
// + non-empty; otherwise that slot degrades to the deterministic template.
function buildAllIdeas(aiById, seeds) {
  const ideas = [];
  for (const pat of seeds) {
    for (const locale of CONTENT_LOCALES) {
      const fb = templateIdea(pat, locale);
      const slot = aiSlot(aiById && aiById[pat.findingId], locale);
      ideas.push({
        title: oneLine(slot.title, MAX_TITLE) || fb.title,
        angle: oneLine(slot.angle, MAX_ANGLE) || fb.angle,
        basedOnPattern: pat.findingId, // OURS — always a real aggregated pattern id
        targetAudience: oneLine(slot.targetAudience, MAX_AUDIENCE) || fb.targetAudience,
        locale,
      });
    }
  }
  return ideas;
}

export async function generateContentIdeas(patterns, env = {}, deps = {}) {
  const pats = Array.isArray(patterns) ? patterns.filter((p) => p && p.findingId) : [];
  const ts = nowIso(deps);
  const top = pats.slice(0, MAX_TOPICS);
  const seeds = top.length ? top : GENERIC_SEEDS; // no history -> evergreen seeds
  const dataBacked = top.length > 0;

  const provider = getAiProvider(env, { fetchImpl: deps.aiFetchImpl });

  // INERT without a key: no request built, NO network call — deterministic templates.
  if (!provider.enabled) {
    return {
      enabled: false,
      provider: 'none',
      source: 'template',
      dataBacked,
      ts,
      ideas: buildAllIdeas(null, seeds),
      note: dataBacked
        ? 'AI content ideas are off (set AI_PROVIDER + AI_API_KEY). These deterministic ideas come from your own recurring audit patterns.'
        : 'No audit history yet — these are evergreen seed ideas. Run more audits, then re-run for data-backed topics. (AI is off.)',
    };
  }

  const user = JSON.stringify(buildIdeaContext(seeds));
  const reply = await provider.chat({ system: IDEAS_SYSTEM_PROMPT, user });

  let aiById = null;
  if (reply && reply.ok === true && reply.text) {
    aiById = normalizeAiIdeas(parseAiJson(reply.text), seeds);
  }
  const result = {
    enabled: true,
    provider: provider.name,
    source: aiById ? 'ai' : 'template',
    dataBacked,
    ts,
    ideas: buildAllIdeas(aiById, seeds),
  };
  if (reply && reply.error) result.error = reply.error;
  if (!aiById && !(reply && reply.error)) {
    result.note = 'The AI reply could not be parsed; degraded to deterministic templates.';
  }
  return result;
}
