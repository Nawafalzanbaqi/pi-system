// pi-system SEO engine — analysis DEPTH selector (pure).
// ===========================================================================
// ONE clear choice the operator makes per run: how DEEP — and how much AI cost —
// to spend on this audit. Same engine, same deterministic findings; depth only
// selects which OPTIONAL layers on top of the rule-based path get invoked.
//
//   quick     rules-only. FREE — 0 AI calls. The existing deterministic path on
//             its own. Fast triage when cost matters and the rules are enough.
//   standard  rules + the EXISTING single-call AI enrichment (ai.js enrich).
//             ≈ 1 AI call billed on YOUR key. The sensible default when AI is set.
//   deep      rules + enrichment + the full multi-specialist panel
//             (5 category specialists + sales-angle + lead synthesis) ≈ up to 7
//             AI calls. The trustworthy "technical team" for high-stakes runs.
//
// Precedence — explicit beats default beats key-presence (pure, deterministic):
//   1. explicit `--depth <level>`   wins (rejected with a clear message if unknown).
//   2. legacy `--panel`             treated as `--depth deep` (back-compat).
//   3. env override SEO_DEFAULT_DEPTH (validated; lets the operator pick a default).
//   4. key-presence default         `standard` when AI is enabled, else `quick` —
//                                   it never half-enables the AI path.
//
// All inputs are validated BEFORE Docker so an unknown value never spends a
// container. The helper scripts re-validate (defence in depth) and the engine
// validates again here — same source of truth for both layers.
// ===========================================================================

import { isAiEnabled } from './ai.js';

export const DEPTHS = ['quick', 'standard', 'deep'];

// True if `value` is one of the documented depth levels.
export function isValidDepth(value) {
  return typeof value === 'string' && DEPTHS.includes(value);
}

// Throw a friendly error for an unknown value, otherwise return the value unchanged.
// Used by every entrypoint so the rejection message is identical across surfaces.
export function assertDepth(value) {
  if (!isValidDepth(value)) {
    throw new Error(`unknown analysis depth '${value}' (expected one of: ${DEPTHS.join(' | ')})`);
  }
  return value;
}

// Resolve the EFFECTIVE depth for a run from the operator inputs + env. Pure,
// side-effect-free (never reads from the network). opts:
//   depth   the explicit --depth <level>, when provided (undefined/null/'' otherwise)
//   panel   the legacy --panel flag — treated as depth=deep when set, for back-compat
// env is process.env (or a stub in tests). SEO_AI_PANEL=1 (the legacy env that made
// --panel the default) is honoured too — same effect as SEO_DEFAULT_DEPTH=deep.
export function resolveDepth(opts = {}, env = process.env) {
  const explicit = opts && opts.depth;
  // `true` from yargs-style "--depth" without a value is treated as "not provided"
  // (the caller should validate flag arity; we never silently accept a bare flag).
  if (explicit !== undefined && explicit !== null && explicit !== '' && explicit !== true) {
    return assertDepth(String(explicit));
  }
  const panel = opts && opts.panel;
  if (panel === true || panel === 'true' || panel === 1 || panel === '1') return 'deep';
  const envOverride = String((env && env.SEO_DEFAULT_DEPTH) || '').trim();
  if (envOverride) return assertDepth(envOverride);
  // Back-compat: SEO_AI_PANEL=1 used to make --panel the default; honour it as deep
  // so a user who set it before the depth selector existed still gets the panel.
  if (String((env && env.SEO_AI_PANEL) || '').trim() === '1') return 'deep';
  return isAiEnabled(env) ? 'standard' : 'quick';
}

// What each depth turns on. Used by the audit pipeline to decide which seam runs.
//   ai     run the single-call enrichment (ai.js enrich)
//   panel  run the multi-specialist panel (specialists.js runSpecialistPanel)
export function capabilitiesFor(depth) {
  const d = assertDepth(depth);
  if (d === 'quick')    return { depth: d, ai: false, panel: false };
  if (d === 'standard') return { depth: d, ai: true,  panel: false };
  return { depth: d, ai: true, panel: true }; // deep
}

// Localized one-line label for the report header — pins the level the report came
// from so a reader can tell "free triage" vs "standard" vs "specialist panel" at a glance.
const DEPTH_LABEL = {
  quick:    { ar: 'سريع — قواعد فقط (مجاني، بدون مكالمات ذكاء اصطناعي)', en: 'quick — rules-only (free, 0 AI calls)' },
  standard: { ar: 'قياسي — إثراء بمكالمة ذكاء اصطناعي واحدة', en: 'standard — single AI enrichment call (~1)' },
  deep:     { ar: 'متعمّق — فريق الخبراء (حتى ٧ مكالمات)', en: 'deep — specialist panel (up to 7 AI calls)' },
};

export function depthLabel(depth, locale) {
  const d = isValidDepth(depth) ? depth : 'standard';
  const l = String(locale || '').toLowerCase().startsWith('en') ? 'en' : 'ar';
  return DEPTH_LABEL[d][l];
}
