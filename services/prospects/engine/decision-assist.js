// pi-system prospect organizer — OPTIONAL AI "decision assist" (advisory only).
// ===========================================================================
// An env-gated helper that advises the OPERATOR about a single prospect. Given that
// prospect's stored site-audit verdict + the operator's OWN notes/status, it asks the
// AI (REUSING the exact same provider seam as services/seo/engine/ai.js — same gate,
// same per-provider request shaping, same injectable fetch) for three things:
//
//   (a) leadScore   an integer 0..100 — how promising this lead is for a web offer
//   (b) nextAction  a recommended next step from a FIXED ALLOWLIST (NEXT_ACTIONS):
//                     research-more | prepare-offer | follow-up | deprioritize
//   (c) rationale   ONE plain-language line explaining the suggestion
//
// HARD BOUNDARIES (architectural, not toggles):
//   * INERT WITHOUT A KEY. With no AI_PROVIDER + AI_API_KEY the provider seam is the
//     inert "none" provider: no request is built, no network call is made, and this
//     returns { enabled:false } so nothing is stored. Identical guarantee to ai.js.
//   * IT ONLY ADVISES. The allowlist contains NO outreach/contact action; there is no
//     code path here (or anywhere in this engine) that messages, emails, or contacts a
//     prospect. The result is advice the operator reads — outreach stays 100% manual.
//   * VALIDATED. The model's reply is parsed defensively and the next action is checked
//     against NEXT_ACTIONS; an off-list or missing value is REJECTED and replaced with
//     a safe default (research-more), never trusted blindly.
//   * PURE behind the injectable provider. The only impure step (the AI call) is the
//     same injectable fetch the SEO seam uses (deps.aiFetchImpl), so the whole path is
//     exercised offline in tests with a mocked fetch (NO real network).
// ===========================================================================

import { getAiProvider, parseAiJson } from '../../seo/engine/ai.js';

// The FIXED allowlist of next actions the assist may recommend. Advisory labels only —
// none of them sends or contacts anything. This list is the whole action surface.
export const NEXT_ACTIONS = ['research-more', 'prepare-offer', 'follow-up', 'deprioritize'];

// The safe default used whenever the model's action is missing or off the allowlist:
// "do more homework" is the most conservative step and never contacts anyone.
export const DEFAULT_ACTION = 'research-more';

// A couple of forgiving spellings -> the canonical allowlist value. Anything not
// resolvable to an allowlist member is rejected (returns null) by normalizeAction.
const ACTION_ALIASES = {
  research: 'research-more',
  'research more': 'research-more',
  'do-more-research': 'research-more',
  offer: 'prepare-offer',
  'prepare offer': 'prepare-offer',
  'make-offer': 'prepare-offer',
  followup: 'follow-up',
  'follow up': 'follow-up',
  deprioritise: 'deprioritize', // British spelling
  'de-prioritize': 'deprioritize',
  drop: 'deprioritize',
};

function nowIso(deps) {
  return new Date(deps && deps.now ? deps.now() : Date.now()).toISOString();
}

// Coerce a model-supplied next action to an allowlist member, or null if it is not one.
export function normalizeAction(value) {
  const raw = String(value || '').trim().toLowerCase();
  if (!raw) return null;
  if (NEXT_ACTIONS.includes(raw)) return raw;
  if (ACTION_ALIASES[raw]) return ACTION_ALIASES[raw];
  const hyphenated = raw.replace(/[\s_]+/g, '-');
  if (NEXT_ACTIONS.includes(hyphenated)) return hyphenated;
  if (ACTION_ALIASES[hyphenated]) return ACTION_ALIASES[hyphenated];
  return null; // off-allowlist -> rejected
}

// Clamp a lead score to an integer in 0..100, or null when it is not a usable number.
export function clampScore(value) {
  const n = Number(value);
  if (!Number.isFinite(n)) return null;
  return Math.max(0, Math.min(100, Math.round(n)));
}

// Collapse a rationale to a single trimmed line, capped in length.
function oneLine(value) {
  const s = String(value == null ? '' : value).replace(/\s+/g, ' ').trim();
  return s.length > 240 ? s.slice(0, 237).trimEnd() + '…' : s;
}

// Build the compact, no-network context the model sees: the operator's own notes +
// pipeline status, and the audit's scores/verdict/counts/summary. Accepts either an
// analyzeProspect result ({ audit, counts, summary }) OR a stored lastAnalysis
// ({ scores, verdict, counts, summary }). No data beyond what the operator entered or
// the audit already computed; nothing is fetched here.
export function buildAssistContext(prospect, analysis) {
  const p = prospect || {};
  const a = analysis || {};
  const audit = a.audit || {};
  const notes = Array.isArray(p.notes)
    ? p.notes.map((n) => (typeof n === 'string' ? n : (n && n.text))).filter(Boolean)
    : [];
  return {
    prospect: {
      id: p.id || null,
      name: p.name || null,
      status: p.status || null,
      hasWebsite: Boolean(p.url),
      followup: p.followup || null,
      notes,
    },
    audit: {
      scores: audit.scores || a.scores || null,
      verdict: audit.verdict || a.verdict || null,
      counts: a.counts || (audit.counts || null),
      summary: a.summary || null,
    },
    allowedActions: NEXT_ACTIONS,
  };
}

// The system prompt: operator-only advisor, NEVER contacts anyone, STRICT JSON shape,
// next action MUST be one of the allowlist values.
const ASSIST_SYSTEM_PROMPT =
  'You are a sales-pipeline assistant for a solo freelance web-services operator. ' +
  'You advise the OPERATOR ONLY. You NEVER contact, message, or email the prospect, and ' +
  'you never draft outreach — you only help the operator decide what to do next. ' +
  'Given the operator\'s own notes and pipeline status plus a site-audit verdict for the ' +
  'prospect\'s public website, respond with STRICT JSON ONLY (no markdown, no text outside ' +
  'the JSON) of exactly this shape: ' +
  '{"leadScore": <integer 0-100>, "nextAction": "<one of: research-more | prepare-offer | ' +
  'follow-up | deprioritize>", "rationale": "<one concise sentence>"}. ' +
  'leadScore reflects how promising this lead is for a web-services offer — weaker sites ' +
  'usually mean more opportunity, but weigh the operator\'s notes and current status. ' +
  'nextAction MUST be exactly one of the four allowed values and nothing else. ' +
  'Keep the rationale to a single line.';

// Turn a (possibly messy) parsed model reply into a SAFE, validated ai_assist record.
// PURE — no I/O. nextAction is always an allowlist member (defaulted when the model's
// value is unusable); leadScore is clamped or null; advisoryOnly is always true.
export function validateAssist(parsed, meta = {}) {
  const base = {
    enabled: true,
    provider: meta.provider || 'unknown',
    ts: meta.ts || new Date().toISOString(),
    advisoryOnly: true, // it ONLY advises the operator; it never contacts anyone
  };
  if (!parsed || typeof parsed !== 'object') {
    return {
      ...base,
      leadScore: null,
      nextAction: DEFAULT_ACTION,
      actionFromModel: false,
      rationale: 'Could not parse a recommendation from the AI reply; defaulting to research-more.',
      valid: false,
    };
  }
  const action = normalizeAction(parsed.nextAction);
  const leadScore = clampScore(parsed.leadScore);
  const rationale = oneLine(parsed.rationale)
    || (action ? `Suggested next step: ${action}.` : 'No rationale provided by the AI.');
  return {
    ...base,
    leadScore,
    nextAction: action || DEFAULT_ACTION, // ALWAYS an allowlist value
    actionFromModel: action !== null, // false => model value was off-allowlist; we defaulted
    rationale,
    valid: action !== null && leadScore !== null,
  };
}

// The orchestrator. Gated by the SEO provider seam (inert without a key). Returns the
// ai_assist record to store under prospect.ai_assist, or { enabled:false } when AI is
// off (in which case nothing was sent and nothing should be stored).
//   prospect  the prospect record (notes/status/url)
//   analysis  an analyzeProspect result OR a stored lastAnalysis (audit context)
//   env       carries AI_PROVIDER / AI_API_KEY / ... (process.env in production)
//   deps      { aiFetchImpl?, now? } — aiFetchImpl is the injectable fetch (tests mock it)
export async function decisionAssist(prospect, analysis = {}, env = {}, deps = {}) {
  const provider = getAiProvider(env, { fetchImpl: deps.aiFetchImpl });
  const ts = nowIso(deps);

  // INERT without a key: no request is built, no network call is made.
  if (!provider.enabled) {
    return {
      enabled: false,
      provider: 'none',
      advisoryOnly: true,
      ts,
      leadScore: null,
      nextAction: null,
      rationale: 'AI decision assist is off (set AI_PROVIDER + AI_API_KEY to enable). The pipeline and analysis are unaffected.',
    };
  }

  const user = JSON.stringify(buildAssistContext(prospect, analysis));
  const reply = await provider.chat({ system: ASSIST_SYSTEM_PROMPT, user });

  // Best-effort: a failed/empty reply must NOT throw — degrade to a safe advisory.
  if (!reply || reply.ok !== true || !reply.text) {
    const why = (reply && (reply.error || reply.note)) ? String(reply.error || reply.note) : 'no response';
    const rec = validateAssist(null, { provider: provider.name, ts });
    rec.rationale = `AI assist unavailable (${why}); defaulting to ${DEFAULT_ACTION}.`;
    if (reply && reply.error) rec.error = reply.error;
    return rec;
  }

  return validateAssist(parseAiJson(reply.text), { provider: provider.name, ts });
}
