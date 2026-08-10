// pi-system SEO engine — OPTIONAL AI enrichment (swappable-provider pattern).
// ===========================================================================
// This mirrors the platform's swappable-provider pattern (whatsapp-integration /
// local-payments): ONE interface, a DEFAULT provider that needs nothing, and a
// real provider that is fully coded but INERT until credentials are supplied.
//
//   default  -> "none" (rule-based only). No network, no key, no cost. This is
//               what runs out of the box: the deterministic rules.js report stands
//               on its own and is never blocked on AI.
//   cloud    -> an OpenAI/Anthropic-COMPATIBLE chat-completions provider, fully
//               implemented below, that ENRICHES the rule-based findings with a
//               RICHER, structured layer. It is selected ONLY when BOTH:
//                   AI_PROVIDER   (e.g. "openai" | "anthropic" | "compatible")
//                   AI_API_KEY    (your own key — usage is billed on YOUR account)
//               are set. With either missing, getAiProvider() returns the inert
//               "none" provider and NO request is ever built or sent.
//
// What the enabled path ADDS (all under the returned `ai` block — it NEVER mutates
// the deterministic `findings` array, which is returned untouched):
//   ai.actionPlan        a single PRIORITISED, DEDUPLICATED action plan that merges
//                        the rule-based findings (each tagged with an effort/impact
//                        estimate: quick-win | medium | large) with the NEW
//                        recommendations the model adds. Rule items are kept verbatim;
//                        AI items that merely restate a rule finding are dropped.
//   ai.executiveSummary  a short, client-facing summary in BOTH Arabic and English
//                        ({ ar, en }) — the platform is Arabic-first. AI-authored when
//                        the model returns it, with a deterministic bilingual fallback
//                        so the shape is ALWAYS present when AI is enabled.
//   ai.suggestions       the raw provider response (kept for debugging / the report).
//
// Flipping it on is a pure env change; no key is committed or required now. The
// network call is isolated behind an injectable `fetchImpl` so the gating decision
// and the whole enrichment shape are unit-testable WITHOUT any real API call (the
// tests pass a stub fetch). Parsing, merging, dedup, effort tagging and the bilingual
// fallback are all pure functions, so a garbled/empty model reply can never break the
// deterministic report — it just degrades to the rule-based action plan + fallback.
//
// Env vars (all documented in the SEO section of .env.example):
//   AI_PROVIDER   openai | anthropic | compatible | none   (default: none/blank)
//   AI_API_KEY    your API key (REQUIRED to enable; usage-billed on your account)
//   AI_MODEL      model id (sane per-provider default if unset)
//   AI_BASE_URL   override the API base URL (for self/compatible endpoints)
// ===========================================================================

// Decide WHICH provider is active from the environment. Pure + side-effect-free,
// so it is the single testable gate. enabled=true ONLY when a real provider is
// named AND a key is present.
export function selectAiProvider(env = process.env) {
  const provider = String(env.AI_PROVIDER || '').trim().toLowerCase();
  const key = String(env.AI_API_KEY || '').trim();

  if (!provider || provider === 'none' || provider === 'rule-based' || provider === 'rules') {
    return { name: 'none', enabled: false, reason: 'AI disabled (default rule-based path)' };
  }
  if (!key) {
    // A provider was named but no key — stay INERT (do not half-enable).
    return { name: 'none', enabled: false, reason: `AI_PROVIDER='${provider}' set but AI_API_KEY is missing — staying rule-based` };
  }
  return { name: provider, enabled: true, reason: `AI enrichment via '${provider}'` };
}

export function isAiEnabled(env = process.env) {
  return selectAiProvider(env).enabled;
}

// Coerce to a positive integer, else 0 (used for the operator-tunable request timeout).
function positiveInt(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

// --- Prioritisation + effort/impact tagging (pure, deterministic) ----------
// Effort tag per recommendation: a rough hands-on estimate so a client can triage.
//   quick-win = under an hour / a single tag or attribute
//   medium    = a few hours / a component or config change across the site
//   large     = real engineering or infrastructure work
export const EFFORTS = ['quick-win', 'medium', 'large'];
const PRIORITY_WEIGHT = { critical: 0, high: 1, medium: 2, low: 3 };
const EFFORT_WEIGHT = { 'quick-win': 0, medium: 1, large: 2 };

// Known rule findings -> their effort estimate (single source of truth shared with
// rules.js by id). Anything unmapped falls back to a priority-based default below.
const EFFORT_BY_ID = {
  // quick wins — a single tag, attribute, or tiny file.
  'title-missing': 'quick-win',
  'title-too-long': 'quick-win',
  'title-too-short': 'quick-win',
  'meta-description-missing': 'quick-win',
  'meta-description-too-long': 'quick-win',
  'h1-missing': 'quick-win',
  'h1-multiple': 'quick-win',
  'viewport-missing': 'quick-win',
  'lang-missing': 'quick-win',
  'canonical-missing': 'quick-win',
  'open-graph-incomplete': 'quick-win',
  'robots-missing': 'quick-win',
  'images-missing-dimensions': 'quick-win',
  'images-not-lazy': 'quick-win',
  'resource-hints-missing': 'quick-win',
  'security-no-nosniff': 'quick-win',
  'security-no-referrer-policy': 'quick-win',
  'security-no-permissions-policy': 'quick-win',
  'security-version-disclosure': 'quick-win',
  // medium — config, a component, or content work spread across the site.
  'no-https': 'medium',
  'sitemap-missing': 'medium',
  'structured-data-missing': 'medium',
  'images-missing-alt': 'medium',
  'html-too-large': 'medium',
  'response-time-slow': 'medium',
  'render-blocking-resources': 'medium',
  'inline-assets-large': 'medium',
  'cls-poor': 'medium',
  'security-no-https': 'medium',
  'security-no-csp': 'medium',
  'security-clickjacking': 'medium',
  'security-no-hsts': 'medium',
  'security-insecure-cookies': 'medium',
  // large — real engineering / infrastructure work.
  'site-unreachable': 'large',
  'response-time-poor': 'large',
  'lcp-poor': 'large',
  'tbt-poor': 'large',
};

function effortFromPriority(priority) {
  switch (priority) {
    case 'critical': return 'large';
    case 'high': return 'medium';
    case 'medium': return 'medium';
    default: return 'quick-win'; // low / unknown
  }
}

// Effort for a deterministic rule finding: explicit map, then low-score-* catch-alls,
// then a priority-based default. Never throws on a partial finding.
function effortForFinding(finding) {
  const id = finding && finding.id ? String(finding.id) : '';
  if (EFFORT_BY_ID[id]) return EFFORT_BY_ID[id];
  if (id.startsWith('low-score-')) return 'large';
  return effortFromPriority(finding && finding.priority);
}

// Coerce a model-supplied effort into the allowed set; fall back to priority.
function normalizeEffort(value, priority) {
  const v = String(value || '').trim().toLowerCase().replace(/[\s_]+/g, '-');
  if (v === 'quick-win' || v === 'quickwin' || v === 'quick' || v === 'easy') return 'quick-win';
  if (v === 'medium' || v === 'moderate' || v === 'med') return 'medium';
  if (v === 'large' || v === 'big' || v === 'high' || v === 'hard') return 'large';
  return effortFromPriority(priority);
}

function normalizePriority(value) {
  const v = String(value || '').trim().toLowerCase();
  return PRIORITY_WEIGHT[v] !== undefined ? v : 'medium';
}

// Normalise a title for dedup: lowercase, collapse to alnum + Arabic letters so an AI
// item that merely rephrases a rule finding ("add a <title> tag" vs "Add a title tag")
// collapses to the same key.
function normTitle(s) {
  return String(s || '').toLowerCase().replace(/[^a-z0-9؀-ۿ]+/g, ' ').trim();
}

function countByPriority(findings) {
  const c = { critical: 0, high: 0, medium: 0, low: 0 };
  for (const x of (findings || [])) if (c[x.priority] !== undefined) c[x.priority] += 1;
  return c;
}

// Stable sort for the action plan: priority first (critical-first), then effort
// (quick-wins first — best ROI early), then rule items before AI items.
function sortActionPlan(items) {
  return items
    .map((x, i) => ({ x, i }))
    .sort((a, b) => {
      const pw = PRIORITY_WEIGHT[a.x.priority] - PRIORITY_WEIGHT[b.x.priority];
      if (pw !== 0) return pw;
      const ew = EFFORT_WEIGHT[a.x.effort] - EFFORT_WEIGHT[b.x.effort];
      if (ew !== 0) return ew;
      if (a.x.source !== b.x.source) return a.x.source === 'rule' ? -1 : 1;
      return a.i - b.i;
    })
    .map((w) => w.x);
}

// Merge the deterministic findings with the AI's NEW recommendations into one
// prioritised, deduplicated action plan. PURE: copies every field into fresh objects,
// so the input `findings` array is never mutated. Rule items always come through;
// AI items that duplicate a rule finding (by id or normalised title) are dropped.
export function buildActionPlan(findings, aiRecs) {
  const plan = [];
  const seen = new Set();

  for (const x of (findings || [])) {
    plan.push({
      id: x.id,
      source: 'rule',
      priority: normalizePriority(x.priority),
      category: x.category || 'seo',
      title: x.title,
      recommendation: x.recommendation,
      effort: effortForFinding(x),
    });
    seen.add(normTitle(x.title));
    if (x.id) seen.add('id:' + String(x.id).toLowerCase());
  }

  let n = 0;
  for (const r of (Array.isArray(aiRecs) ? aiRecs : [])) {
    const title = String((r && (r.title || r.recommendation)) || '').trim();
    if (!title) continue;
    const titleKey = normTitle(title);
    const idKey = r && r.id ? 'id:' + String(r.id).toLowerCase() : '';
    if (seen.has(titleKey) || (idKey && seen.has(idKey))) continue; // dedup vs rules + earlier AI items
    seen.add(titleKey);
    if (idKey) seen.add(idKey);
    n += 1;
    const priority = normalizePriority(r && r.priority);
    const item = {
      id: (r && r.id) ? String(r.id) : `ai-${n}`,
      source: 'ai',
      priority,
      category: (r && r.category) ? String(r.category) : 'seo',
      title,
      recommendation: String((r && r.recommendation) || title),
      effort: normalizeEffort(r && r.effort, priority),
    };
    if (r && r.impact) item.impact = String(r.impact);
    plan.push(item);
  }

  return sortActionPlan(plan);
}

// --- Bilingual executive summary (Arabic-first) ----------------------------
const TIER_AR = { excellent: 'ممتاز', good: 'جيد', fair: 'مقبول', poor: 'ضعيف' };

function tierWord(overall) {
  if (overall >= 90) return 'excellent';
  if (overall >= 75) return 'good';
  if (overall >= 50) return 'fair';
  return 'poor';
}

// Simple average of whatever category scores are present — only used as a fallback
// when the audit carries no pre-computed verdict.overall.
function overallFromScores(scores) {
  const vals = Object.values(scores || {}).filter((n) => Number.isFinite(n));
  if (!vals.length) return 0;
  return Math.round(vals.reduce((s, n) => s + n, 0) / vals.length);
}

// Deterministic bilingual summary from the audit + findings. Guarantees the { ar, en }
// shape even if the model omits it or returns nothing parseable.
export function fallbackSummary(audit, findings) {
  const a = audit || {};
  const v = a.verdict || {};
  const counts = countByPriority(findings);
  const total = (findings || []).length;
  const name = a.name || a.url || 'the site';
  const overall = Number.isFinite(v.overall) ? v.overall : overallFromScores(a.scores);
  const tier = v.tier || tierWord(overall);
  const tierAr = TIER_AR[tier] || tier;

  const ar =
    `التقييم العام لموقع ${name}: ${overall}/100 (${tierAr}). ` +
    `تم رصد ${total} ملاحظة (${counts.critical} حرجة، ${counts.high} عالية، ${counts.medium} متوسطة، ${counts.low} منخفضة). ` +
    (total > 0
      ? 'يُنصح بالبدء بالملاحظات الحرجة وذات الأولوية العالية، ثم المكاسب السريعة.'
      : 'الموقع في حالة جيدة ولا توجد ملاحظات جوهرية.');

  const en =
    `Overall assessment for ${name}: ${overall}/100 (${tier}). ` +
    `${total} finding(s) detected (${counts.critical} critical, ${counts.high} high, ${counts.medium} medium, ${counts.low} low). ` +
    (v.opportunity
      ? v.opportunity
      : (total > 0
          ? 'Start with the critical and high-priority items, then the quick wins.'
          : 'The site is in good shape with no material findings.'));

  return { ar, en };
}

// Prefer the model's Arabic/English where present (non-empty), else fall back per-language.
function mergeSummary(aiSummary, fallback) {
  const s = (aiSummary && typeof aiSummary === 'object') ? aiSummary : {};
  const ar = String(s.ar || s.arabic || '').trim();
  const en = String(s.en || s.english || '').trim();
  return { ar: ar || fallback.ar, en: en || fallback.en };
}

// Tolerant JSON extraction from a model reply (handles ```json fences and surrounding
// prose). Returns the parsed object or null — never throws. Exported so other engines
// that reuse this provider seam (e.g. the prospects decision-assist) parse replies the
// SAME defensive way instead of duplicating it.
export function parseAiJson(text) {
  if (!text || typeof text !== 'string') return null;
  let s = text.trim();
  const fence = s.match(/```(?:json)?\s*([\s\S]*?)```/i);
  if (fence) s = fence[1].trim();
  const first = s.indexOf('{');
  const last = s.lastIndexOf('}');
  if (first === -1 || last === -1 || last < first) return null;
  try {
    const obj = JSON.parse(s.slice(first, last + 1));
    return (obj && typeof obj === 'object') ? obj : null;
  } catch {
    return null;
  }
}

// The inert default: contributes nothing, talks to nothing.
function createRuleBasedProvider() {
  return {
    name: 'none',
    enabled: false,
    // Generic primitive (mirrors the cloud provider) — inert: no network, no reply.
    async chat() {
      return { ok: false, disabled: true };
    },
    async suggest() {
      return []; // no enrichment — the rule-based findings are the whole report.
    },
  };
}

// Per-provider request shaping for OpenAI- and Anthropic-compatible HTTP APIs. The
// prompt asks for STRICT JSON (bilingual executive summary + NEW recommendations with
// effort tags); the engine parses it defensively, so a non-JSON reply degrades cleanly.
function providerRequest(provider, { model, key, baseUrl, system, user }) {
  if (provider === 'anthropic') {
    return {
      url: (baseUrl || 'https://api.anthropic.com') + '/v1/messages',
      init: {
        method: 'POST',
        headers: {
          'content-type': 'application/json',
          'x-api-key': key,
          'anthropic-version': '2023-06-01',
        },
        body: JSON.stringify({
          model: model || 'claude-haiku-4-5-20251001',
          max_tokens: 1500,
          system,
          messages: [{ role: 'user', content: user }],
        }),
      },
      extract: (json) => (json?.content?.[0]?.text || '').trim(),
    };
  }
  // openai | compatible (OpenAI chat-completions schema — the de-facto standard).
  return {
    url: (baseUrl || 'https://api.openai.com/v1') + '/chat/completions',
    init: {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${key}`,
      },
      body: JSON.stringify({
        model: model || 'gpt-4o-mini',
        max_tokens: 1500,
        messages: [
          { role: 'system', content: system },
          { role: 'user', content: user },
        ],
      }),
    },
    extract: (json) => (json?.choices?.[0]?.message?.content || '').trim(),
  };
}

// The system prompt: Arabic-first, NEW recommendations only, STRICT JSON shape.
const SYSTEM_PROMPT =
  'You are a senior SEO and web-performance consultant for an Arabic-first ' +
  'freelance platform. You receive a full site audit (five category scores: ' +
  'performance, accessibility, best-practices, seo, security; an overall verdict; ' +
  'metrics; and on-page checks) plus the deterministic, rule-based findings already ' +
  'produced. Do NOT repeat or restate the existing findings. Respond with STRICT JSON ' +
  'ONLY — no markdown, no commentary outside the JSON — of exactly this shape: ' +
  '{"executiveSummary":{"ar":"<2-3 sentence client-facing summary in Arabic>",' +
  '"en":"<the same summary in English>"},' +
  '"recommendations":[{"title":"<short title>","recommendation":"<what to do>",' +
  '"priority":"critical|high|medium|low",' +
  '"category":"performance|accessibility|best-practices|seo|security",' +
  '"effort":"quick-win|medium|large","impact":"<one short phrase>"}]}. ' +
  'The executive summary must be understandable by a non-technical client, Arabic first. ' +
  'Every recommendation must be NEW (not already among the findings), specific, and carry ' +
  'an honest effort estimate (quick-win = under an hour / a single tag; medium = a few ' +
  'hours / a component; large = real engineering or infrastructure work).';

// The real provider — fully coded, but only ever constructed when enabled. suggest()
// returns the RAW provider reply ([{source,text}] | [{source,error}] | [{note}] | []);
// enrich() turns that raw text into the structured enrichment.
function createCloudProvider(env, deps) {
  const provider = String(env.AI_PROVIDER || '').trim().toLowerCase();
  const key = String(env.AI_API_KEY || '').trim();
  const model = String(env.AI_MODEL || '').trim() || null;
  const baseUrl = String(env.AI_BASE_URL || '').trim() || null;
  const fetchImpl = (deps && deps.fetchImpl) || globalThis.fetch;
  // Bound the request in TIME so a hung/slow provider can never stall the one-shot
  // audit container (it would hold RAM until externally killed). Operator-tunable.
  const timeoutMs = positiveInt(env.AI_TIMEOUT_MS) || 30000;

  // The single low-level call: shape the request per provider, hit the injectable
  // fetch, return the raw text. Best-effort: returns { ok, text } or { ok:false, ... }
  // and NEVER throws, so every caller degrades cleanly. This is the seam other engines
  // reuse to ask the SAME provider a DIFFERENT question (their own system/user prompt).
  async function chat({ system, user }) {
    if (typeof fetchImpl !== 'function') {
      return { ok: false, note: 'AI enabled but no fetch implementation available; skipped.' };
    }
    const req = providerRequest(provider, { model, key, baseUrl, system, user });
    // Best-effort: on a timeout or any error we return { ok:false } and the report
    // degrades to the deterministic rule-based path — the AI layer NEVER throws.
    const ac = typeof AbortController !== 'undefined' ? new AbortController() : null;
    const timer = ac ? setTimeout(() => ac.abort(), timeoutMs) : null;
    try {
      const res = await fetchImpl(req.url, { ...req.init, signal: ac ? ac.signal : undefined });
      const json = await res.json();
      return { ok: true, text: req.extract(json) };
    } catch (err) {
      const msg = err && err.name === 'AbortError'
        ? `AI request timed out after ${timeoutMs}ms`
        : String((err && err.message) || err);
      return { ok: false, error: msg };
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  return {
    name: provider,
    enabled: true,
    chat,
    async suggest(audit, findings) {
      // Pass the FULL audit (all five category scores + the verdict + metrics + checks)
      // plus a compact view of the existing findings so the model can avoid repeating them.
      const user = JSON.stringify({
        url: audit.url,
        name: audit.name,
        scores: audit.scores,
        verdict: audit.verdict,
        metrics: audit.metrics,
        checks: audit.checks,
        existingFindings: (findings || []).map((x) => ({
          id: x.id, priority: x.priority, category: x.category, title: x.title, recommendation: x.recommendation,
        })),
      });
      const r = await chat({ system: SYSTEM_PROMPT, user });
      if (r.note) return [{ note: r.note }];
      if (r.error) return [{ source: provider, error: r.error }]; // best-effort — never breaks the report
      return r.text ? [{ source: provider, text: r.text }] : [];
    },
  };
}

// The factory the rest of the engine calls. Returns the inert default unless the
// env unlocks the cloud provider. `deps.fetchImpl` lets tests inject a stub.
export function getAiProvider(env = process.env, deps = {}) {
  const sel = selectAiProvider(env);
  if (!sel.enabled) return createRuleBasedProvider();
  return createCloudProvider(env, deps);
}

// Enrich rule-based findings. Returns:
//   { findings, ai: { enabled, provider, suggestions, actionPlan, executiveSummary, error? } }
// The `findings` array is returned UNCHANGED — AI only ADDS structured fields under the
// `ai` block — so the deterministic report is always intact whether or not AI is on.
//
// When DISABLED (the default, or a provider named without a key): no network call is
// ever made, and the AI-only fields are empty (actionPlan: [], executiveSummary: null).
// When ENABLED: the bilingual executiveSummary and the merged/tagged actionPlan are
// ALWAYS present — a garbled or empty model reply degrades to the deterministic
// fallback summary + the rule-based action plan, never an exception.
export async function enrich(findings, audit, env = process.env, deps = {}) {
  const provider = getAiProvider(env, deps);
  if (!provider.enabled) {
    return {
      findings,
      ai: { enabled: false, provider: 'none', suggestions: [], actionPlan: [], executiveSummary: null },
    };
  }

  const suggestions = await provider.suggest(audit, findings);
  const text = suggestions.map((s) => s && s.text).filter(Boolean).join('\n').trim();
  const error = suggestions.map((s) => s && s.error).filter(Boolean)[0] || null;

  const parsed = parseAiJson(text);
  const executiveSummary = mergeSummary(parsed && parsed.executiveSummary, fallbackSummary(audit, findings));
  const aiRecs = (parsed && Array.isArray(parsed.recommendations)) ? parsed.recommendations : [];
  const actionPlan = buildActionPlan(findings, aiRecs);

  const ai = { enabled: true, provider: provider.name, suggestions, actionPlan, executiveSummary };
  if (error) ai.error = error;
  return { findings, ai };
}
