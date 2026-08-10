// pi-system SEO engine — the OVERALL prospect verdict (the sales-angle roll-up).
// ===========================================================================
// computeVerdict(audit) folds a full audit — its five deterministic category
// scores (scoring.js) PLUS its prioritised findings (rules.js) — into ONE
// prospect-level assessment a salesperson can read at a glance:
//
//   { overall, tier, topFindings, opportunity }
//
//   overall      0..100 — the WEIGHTED average of the category scores:
//                  seo 0.30, performance 0.25, security 0.20,
//                  best-practices 0.15, accessibility 0.10.
//                The weights RE-NORMALISE over whatever categories are actually
//                present, so an older audit lacking the (newer) security category
//                still scores sanely instead of being silently dragged toward 0.
//   tier         excellent (≥90) | good (≥75) | fair (≥50) | poor (<50).
//   topFindings  the three highest-priority findings (critical-first), each a
//                compact { id, priority, category, title, recommendation }.
//   opportunity  ONE plain-language line naming the single biggest improvement
//                opportunity — the sales hook ("Biggest win: …").
//
// Pure + deterministic: same audit => same verdict. It derives the findings itself
// via rules.analyze (or honours audit.findings if a caller already attached them) and
// re-sorts them critical-first, so it needs nothing but the audit object. Wired into
// buildAudit (probe.js) and re-run after the Lighthouse score override
// (lighthouse-adapter.js) so EVERY audit — probe or lighthouse, reachable or not —
// carries an audit.verdict computed from its FINAL scores.
// ===========================================================================

import { analyze, sortFindings } from './rules.js';

// Category weights for the overall score (sum to 1.0). Re-normalised over the
// categories actually present so a missing category never silently counts as 0.
export const VERDICT_WEIGHTS = {
  seo: 0.30,
  performance: 0.25,
  security: 0.20,
  'best-practices': 0.15,
  accessibility: 0.10,
};

// Tier cut-offs on the 0..100 overall score, highest-first.
export const TIERS = [
  { tier: 'excellent', min: 90 },
  { tier: 'good', min: 75 },
  { tier: 'fair', min: 50 },
  { tier: 'poor', min: 0 },
];

function tierFor(overall) {
  for (const t of TIERS) if (overall >= t.min) return t.tier;
  return 'poor';
}

// Weighted average of the category scores, re-normalised over the present categories.
function overallScore(scores) {
  let weighted = 0;
  let total = 0;
  for (const [cat, w] of Object.entries(VERDICT_WEIGHTS)) {
    const v = scores[cat];
    if (Number.isFinite(v)) { weighted += v * w; total += w; }
  }
  if (total === 0) return 0;
  return Math.max(0, Math.min(100, Math.round(weighted / total)));
}

// One plain-language sales line: the single biggest improvement opportunity.
function opportunityLine(audit, findings, overall) {
  if (audit && audit.ok === false) {
    return 'The site is unreachable right now — getting it back online is the most urgent fix.';
  }
  if (findings.length === 0) {
    return `No major issues found — the site scores ${overall}/100 overall and is in strong shape.`;
  }
  const top = findings[0];
  return `Biggest win: ${top.title} — a ${top.priority}-priority ${top.category} fix.`;
}

// Trim a finding to the fields a prospect summary actually needs.
const compact = (x) => ({
  id: x.id,
  priority: x.priority,
  category: x.category,
  title: x.title,
  recommendation: x.recommendation,
});

export function computeVerdict(audit) {
  const a = audit || {};
  const scores = a.scores || {};
  // Honour pre-attached findings if present; otherwise derive them. Re-sort either
  // way so "top" is always the highest priority regardless of the input order.
  const findings = sortFindings(Array.isArray(a.findings) ? a.findings : analyze(a));
  const overall = overallScore(scores);
  return {
    overall,
    tier: tierFor(overall),
    topFindings: findings.slice(0, 3).map(compact),
    opportunity: opportunityLine(a, findings, overall),
  };
}
