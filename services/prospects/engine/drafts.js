// pi-system prospect organizer — OPTIONAL AI-assisted DRAFT generator (copy-yourself).
// ===========================================================================
// Turns a COMPLETED prospect audit into copy-paste-ready OPERATOR drafts. It only
// ever DRAFTS text the operator reviews, personalizes, and sends HIMSELF — it does
// NOT send anything, has NO transport (no SMTP/WhatsApp/HTTP client of its own), and
// adds NO send path to the engine. The same architectural boundary as templates.js /
// alert.js: the no-send/no-scrape tests must stay green.
//
//   generateDrafts(prospect, audit, env, deps) -> { enabled, provider, source, ts,
//     drafts: [ { kind, locale, subject?, body, basedOn:[findingIds] } ] }
//
// It produces THREE kinds, each in Arabic (first) AND English:
//   * outreach          — a warm, value-first message to the business that references the
//                         1-2 biggest concrete issues found in THIS audit (e.g. slow load,
//                         missing HTTPS), professional Saudi-market tone, no spam patterns,
//                         ending with a soft, optional call to action.
//   * referral-request  — a short message to send an EXISTING happy client asking for an
//                         introduction to someone who might benefit.
//   * content-snippet   — a teaching social post derived from the audit's findings
//                         (educational, attracts inbound; NOT about a specific named client).
//
// HARD BOUNDARIES (architectural, not toggles), identical to decision-assist.js:
//   * INERT WITHOUT A KEY. With no AI_PROVIDER + AI_API_KEY the provider seam is the
//     inert "none" provider: no request is built, NO network call is made, and the result
//     is the DETERMINISTIC template fallback (enabled:false). Same guarantee as ai.js.
//   * IT ONLY DRAFTS. There is no contact/send code path here or anywhere this is wired.
//   * VALIDATED + CLAMPED. The model reply is parsed defensively (parseAiJson) and every
//     field is clamped; a garbled/empty/erroring reply degrades PER-SLOT to the template
//     fallback. It NEVER throws and NEVER makes a network call without a key.
//   * basedOn is computed by US from the audit's own findings (real ids) — never trusted
//     from the model — so it always references findings that exist in this audit.
//   * PURE behind the injectable provider (deps.aiFetchImpl) — fully offline-testable.
// ===========================================================================

import { getAiProvider, parseAiJson } from '../../seo/engine/ai.js';

export const DRAFT_KINDS = ['outreach', 'referral-request', 'content-snippet'];
export const DRAFT_LOCALES = ['ar', 'en'];

// Friendly CLI aliases -> the canonical kind. Anything else -> null (rejected).
const KIND_ALIASES = {
  outreach: 'outreach',
  referral: 'referral-request',
  'referral-request': 'referral-request',
  content: 'content-snippet',
  'content-snippet': 'content-snippet',
};

export function normalizeDraftKind(value) {
  const k = String(value || '').trim().toLowerCase().replace(/[\s_]+/g, '-');
  return KIND_ALIASES[k] || null;
}

// Arabic for anything that is not explicitly English (RTL-first default).
export function normLocale(locale) {
  return String(locale || '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}

const MAX_BODY = 1500;
const MAX_SUBJECT = 160;
const PRIORITY_WEIGHT = { critical: 0, high: 1, medium: 2, low: 3 };

// Localized category phrasing for the deterministic fallback (titles otherwise stay in
// the SEO engine's own English, per the platform convention used by alert.js/report.js).
const CAT = {
  ar: {
    performance: 'سرعة الموقع', security: 'أمان الموقع', seo: 'الظهور في محركات البحث',
    accessibility: 'سهولة الوصول للجميع', 'best-practices': 'الجودة التقنية',
  },
  en: {
    performance: 'page speed', security: 'site security', seo: 'search visibility',
    accessibility: 'accessibility', 'best-practices': 'technical best-practices',
  },
};

function nowIso(deps) {
  return new Date(deps && deps.now ? deps.now() : Date.now()).toISOString();
}

// Collapse to a single trimmed line, capped (for subjects).
function oneLine(value, max = MAX_SUBJECT) {
  const t = String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
  return t.length > max ? t.slice(0, max - 1).trimEnd() + '…' : t;
}

// Tidy a body: normalise newlines, drop trailing spaces, collapse blank runs, cap length.
function clampBody(value, max = MAX_BODY) {
  let t = String(value == null ? '' : value)
    .replace(/\r\n/g, '\n')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\n{3,}/g, '\n\n')
    .trim();
  if (t.length > max) t = t.slice(0, max - 1).trimEnd() + '…';
  return t;
}

// The 1-2 biggest concrete issues in THIS audit (critical-first). Reads attached
// findings if present, else the verdict's topFindings (which the prospect store keeps).
export function topIssues(audit, n = 2) {
  const a = audit || {};
  let list = Array.isArray(a.findings) && a.findings.length
    ? a.findings
    : (a.verdict && Array.isArray(a.verdict.topFindings) ? a.verdict.topFindings : []);
  list = list.slice().sort((x, y) => (PRIORITY_WEIGHT[x.priority] ?? 9) - (PRIORITY_WEIGHT[y.priority] ?? 9));
  return list.slice(0, n).map((f) => ({
    id: f.id, title: f.title, category: f.category, priority: f.priority, recommendation: f.recommendation,
  }));
}

// Localized phrases for the issues (Arabic by category, English by title).
function issuePhrases(loc, issues) {
  return (issues || []).map((i) =>
    loc === 'ar' ? (CAT.ar[i.category] || i.title || 'تحسينات على الموقع')
                 : (i.title || CAT.en[i.category] || 'site improvements'));
}

// --- Deterministic, bilingual TEMPLATE fallback (always available) ----------
function fallbackContent(kind, loc, name, issues) {
  const phrases = issuePhrases(loc, issues);
  const biz = name || (loc === 'ar' ? '[اسم النشاط]' : '[BUSINESS NAME]');

  if (kind === 'outreach') {
    if (loc === 'ar') {
      const noticed = phrases.length
        ? `لاحظت فرصتين بسيطتين لتحسين ${phrases.join(' و')}`
        : 'لاحظت بعض الفرص البسيطة لتحسين الموقع';
      return {
        subject: `ملاحظات سريعة حول موقع ${biz}`,
        body: [
          'السلام عليكم،',
          '',
          `اطّلعت على موقع ${biz} وأعجبني ما تقدّمونه. ${noticed} بما قد ينعكس على تجربة الزوّار وظهوركم في نتائج البحث.`,
          '',
          'يسعدني مشاركتكم ملخصاً مختصراً وواضحاً دون أي التزام. إن رغبتم، يمكننا ترتيب محادثة قصيرة في الوقت المناسب لكم.',
          '',
          'مع خالص التقدير،',
          '[اسمك] · [هاتفك]',
        ].join('\n'),
      };
    }
    const noticed = phrases.length
      ? `I noticed a couple of small opportunities around ${phrases.join(' and ')}`
      : 'I noticed a few small opportunities on the site';
    return {
      subject: `A few quick notes on the ${biz} website`,
      body: [
        'Hello,',
        '',
        `I took a look at the ${biz} website and liked what you offer. ${noticed} that could improve the visitor experience and your visibility in search.`,
        '',
        "I'd be glad to share a short, plain-language summary with no obligation. If it's useful, we could set up a brief chat at a time that suits you.",
        '',
        'Warm regards,',
        '[YOUR NAME] · [YOUR PHONE]',
      ].join('\n'),
    };
  }

  if (kind === 'referral-request') {
    if (loc === 'ar') {
      return {
        subject: 'طلب توصية لطيف',
        body: [
          'السلام عليكم [اسم العميل]،',
          '',
          'سعدت بالعمل معكم، وأتمنى أن تكون النتائج قد نالت رضاكم. أعمل حالياً على خدمة عدد أكبر من أصحاب الأعمال.',
          '',
          'إن كان لديكم معرفة بصاحب نشاط قد يستفيد من تحسين موقعه أو أدائه أو ظهوره في البحث، فسيشرّفني أن تقدّموني له — تكفي كلمة طيبة منكم.',
          '',
          'شكراً لثقتكم،',
          '[اسمك]',
        ].join('\n'),
      };
    }
    return {
      subject: 'A small referral favor',
      body: [
        'Hi [CLIENT NAME],',
        '',
        "It's been a pleasure working with you, and I hope you've been happy with the results. I'm currently looking to help a few more business owners.",
        '',
        'If you know anyone whose website could use improvement in speed, security, or search visibility, I’d be grateful for a quick introduction — a kind word from you goes a long way.',
        '',
        'Thank you for your trust,',
        '[YOUR NAME]',
      ].join('\n'),
    };
  }

  // content-snippet — an educational post (no subject), not about a named client.
  if (loc === 'ar') {
    const tips = (phrases.length ? phrases : ['سرعة التحميل', 'تأمين الموقع عبر HTTPS', 'وصف واضح لكل صفحة'])
      .map((p) => `• ${p}`).join('\n');
    return {
      body: [
        '💡 نقاط بسيطة تصنع فرقاً كبيراً في أي موقع:',
        '',
        tips,
        '',
        'معظم هذه التحسينات لا تستغرق وقتاً طويلاً، لكنها تنعكس مباشرة على سرعة الموقع وثقة الزوّار وترتيبك في نتائج البحث.',
        '',
        '#تطوير_المواقع #تحسين_الأداء #SEO',
      ].join('\n'),
    };
  }
  const tips = (phrases.length ? phrases : ['load speed', 'securing the site with HTTPS', 'a clear description for every page'])
    .map((p) => `• ${p}`).join('\n');
  return {
    body: [
      '💡 Small things that make a big difference on any website:',
      '',
      tips,
      '',
      "Most of these take little time, but they pay off directly in speed, visitor trust, and search ranking.",
      '',
      '#WebDevelopment #Performance #SEO',
    ].join('\n'),
  };
}

// The compact, no-network context the model sees (only what the audit already computed
// + what the operator entered). Nothing is fetched here.
export function buildDraftContext(prospect, audit, issues) {
  const p = prospect || {};
  const a = audit || {};
  return {
    business: { name: p.name || a.name || null, url: p.url || a.url || null },
    audit: {
      scores: a.scores || null,
      verdict: a.verdict ? { overall: a.verdict.overall, tier: a.verdict.tier } : null,
    },
    topIssues: (issues || []).map((i) => ({
      id: i.id, title: i.title, category: i.category, priority: i.priority, recommendation: i.recommendation,
    })),
    kinds: ['outreach', 'referral', 'content'],
    locales: ['ar', 'en'],
  };
}

const DRAFTS_SYSTEM_PROMPT =
  'You are a copywriting assistant for a SOLO freelance web-services operator in Saudi Arabia. ' +
  'You write DRAFTS the OPERATOR will copy, personalize, and send HIMSELF — you NEVER send anything, ' +
  'never contact anyone, and never ask for contact details. Given a business name, its public-site ' +
  'audit, and the 1-2 biggest concrete issues found, write THREE drafts, each in Arabic (first) AND ' +
  'English. Tone: warm, professional, value-first, suited to the Saudi market; NO spam, NO hype, NO ' +
  'pressure, NO fake urgency, NO bulk-mail clichés. Respond with STRICT JSON ONLY (no markdown, no text ' +
  'outside the JSON) of exactly this shape: ' +
  '{"outreach":{"ar":{"subject":"..","body":".."},"en":{"subject":"..","body":".."}},' +
  '"referral":{"ar":{"subject":"..","body":".."},"en":{"subject":"..","body":".."}},' +
  '"content":{"ar":{"body":".."},"en":{"body":".."}}}. ' +
  'outreach = a message to THIS business that references the 1-2 concrete issues and ends with a SOFT, ' +
  'optional call to action. referral = a short message to send an EXISTING happy client asking for an ' +
  'introduction. content = a short EDUCATIONAL social post teaching the lesson behind the findings to ' +
  'attract inbound — NOT about any specific named client. Keep each body under ~120 words, natural and ' +
  'human, Arabic first. Do not invent facts beyond the provided issues. Use only the placeholders ' +
  '[اسمك]/[YOUR NAME], [هاتفك]/[YOUR PHONE], [اسم العميل]/[CLIENT NAME].';

// Map a parsed model reply onto the canonical kinds, tolerating alias keys. Returns null
// when nothing usable is present (so the caller degrades wholesale to the templates).
function normalizeAiDrafts(parsed) {
  if (!parsed || typeof parsed !== 'object') return null;
  const pick = (...keys) => {
    for (const k of keys) if (parsed[k] && typeof parsed[k] === 'object') return parsed[k];
    return null;
  };
  const out = {
    outreach: pick('outreach'),
    'referral-request': pick('referral', 'referral-request', 'referralRequest'),
    'content-snippet': pick('content', 'content-snippet', 'contentSnippet'),
  };
  const usable = Object.values(out).some((v) => v && (v.ar || v.en));
  return usable ? out : null;
}

// Extract a per-locale {subject?, body} slot from a model kind object (string or object).
function aiSlot(aiKind, locale) {
  if (!aiKind || typeof aiKind !== 'object') return {};
  const v = aiKind[locale];
  if (typeof v === 'string') return { body: v };
  if (v && typeof v === 'object') return v;
  return {};
}

function makeDraft(kind, locale, subject, body, issues) {
  // basedOn is OURS, from the audit — outreach/content reference the concrete issues; a
  // referral request is not finding-specific.
  const basedOn = kind === 'referral-request'
    ? []
    : (issues || []).map((i) => i.id).filter(Boolean);
  const d = { kind, locale, body, basedOn };
  if (kind !== 'content-snippet' && subject) d.subject = subject;
  return d;
}

// Build all six drafts (3 kinds × 2 locales). AI text is used PER SLOT when present +
// non-empty; otherwise that slot degrades to the deterministic template — so a partial
// or garbled reply never leaves a hole.
function buildAll(aiByKind, name, issues) {
  const items = [];
  for (const kind of DRAFT_KINDS) {
    for (const locale of DRAFT_LOCALES) {
      const fb = fallbackContent(kind, locale, name, issues);
      const slot = aiSlot(aiByKind && aiByKind[kind], locale);
      const body = clampBody(slot.body) || fb.body;
      const subject = kind === 'content-snippet'
        ? undefined
        : (oneLine(slot.subject) || fb.subject);
      items.push(makeDraft(kind, locale, subject, body, issues));
    }
  }
  return items;
}

export async function generateDrafts(prospect, audit, env = {}, deps = {}) {
  const p = prospect || {};
  const a = audit || {};
  const name = p.name || a.name || null;
  const issues = topIssues(a, 2);
  const ts = nowIso(deps);

  const provider = getAiProvider(env, { fetchImpl: deps.aiFetchImpl });

  // INERT without a key: no request built, NO network call — deterministic templates.
  if (!provider.enabled) {
    return {
      enabled: false,
      provider: 'none',
      source: 'template',
      ts,
      drafts: buildAll(null, name, issues),
      note: 'AI draft generation is off (set AI_PROVIDER + AI_API_KEY to enable). These are deterministic templates — review, personalize, and send them yourself.',
    };
  }

  const user = JSON.stringify(buildDraftContext(p, a, issues));
  const reply = await provider.chat({ system: DRAFTS_SYSTEM_PROMPT, user });

  // Best-effort: a failed/empty/garbled reply degrades to the templates — never throws.
  let aiByKind = null;
  if (reply && reply.ok === true && reply.text) {
    aiByKind = normalizeAiDrafts(parseAiJson(reply.text));
  }
  const result = {
    enabled: true,
    provider: provider.name,
    source: aiByKind ? 'ai' : 'template',
    ts,
    drafts: buildAll(aiByKind, name, issues),
  };
  if (reply && reply.error) result.error = reply.error;
  if (!aiByKind && !(reply && reply.error)) {
    result.note = 'The AI reply could not be parsed; degraded to deterministic templates.';
  }
  return result;
}
