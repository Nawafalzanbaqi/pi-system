// pi-system SEO engine — COMPETITOR comparison (pure orchestration).
// ===========================================================================
// Side-by-side "us vs them" using REAL audits — never an invented figure.
// The operator types the competitor URLs themselves (no scrape, no discovery).
// Each URL goes through the SAME SSRF-guarded probe + the SAME rules/scoring
// pipeline as the primary; a blocked/failed competitor is recorded as such and
// is NEVER fatal (the comparison still renders, just notes which one didn't run).
//
// Surface:
//   * MAX_COMPETITORS — hard cap so an audit's time + memory stay predictable.
//   * compareSites(primary, [competitor, ...]) -> deterministic comparison shape
//     (PURE; no I/O). The "key gaps" list is the categories where the primary
//     trails by ≥ GAP_THRESHOLD points; for performance the gap also surfaces
//     the response-time pair (e.g. "loads in 5.0s vs 1.8s") taken FROM the
//     audit.metrics.responseMs of EACH side — never invented.
//   * probeCompetitors(urls, deps) -> async; runs probeUrl per URL (the SAME
//     SSRF guard). Bounded to MAX_COMPETITORS — over-cap is refused with a
//     clear error so the caller can surface it.
//   * renderCompetitorSection(comparison, opts) -> bilingual Markdown section
//     for buildProspectReport. Additive: empty/missing data → ''.
//
// HALLUCINATION DISCIPLINE: this module never accepts model output. Every number
// printed is a field of an audit object the SEO engine itself produced — same
// guarantee as guardNumbers in specialists.js, but here it is structural: there
// is no AI seam to defend against.
// ===========================================================================

import { probeUrl } from './probe.js';
import { computeVerdict } from './verdict.js';

// Hard cap. Three is enough for a side-by-side and keeps audit time bounded.
export const MAX_COMPETITORS = 3;
// A category gap below this is too small to call out as a "key gap" (avoids noise).
const GAP_THRESHOLD = 5;
// Categories surfaced in the comparison table, client-facing order.
const CATEGORIES = ['seo', 'performance', 'security', 'best-practices', 'accessibility'];

const CAT_AR = {
  seo: 'تحسين محركات البحث', performance: 'الأداء', security: 'الأمان',
  'best-practices': 'أفضل الممارسات', accessibility: 'سهولة الوصول',
};
const CAT_EN = {
  seo: 'SEO', performance: 'Performance', security: 'Security',
  'best-practices': 'Best practices', accessibility: 'Accessibility',
};

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------
function normLocale(locale) {
  return String(locale || '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}

// A failed/blocked audit carries a string status like "blocked by SSRF guard: ..."
// — surface it as a structured reason so the renderer can name what happened.
function blockedReasonOf(audit) {
  if (!audit || audit.ok !== false) return null;
  const status = audit.status;
  if (typeof status === 'string' && /^blocked by ssrf guard/i.test(status)) return status;
  if (typeof status === 'string' && status.trim()) return status;
  return null;
}

// A compact, comparison-ready view of one audit. Every number here was MEASURED
// (response time, scores, overall) by the SEO engine — there is no synthesis.
function compactAudit(audit) {
  const a = audit || {};
  const verdict = (a.verdict && typeof a.verdict === 'object') ? a.verdict : computeVerdict(a);
  const m = a.metrics || {};
  return {
    name: a.name || null,
    url: a.url || null,
    ok: !!a.ok,
    status: (a.status === undefined ? null : a.status),
    blockedReason: blockedReasonOf(a),
    scores: a.scores || {},
    verdict: verdict ? { overall: verdict.overall, tier: verdict.tier } : null,
    metrics: { responseMs: m.responseMs, htmlBytes: m.htmlBytes },
  };
}

// compareSites(primary, competitors) -> { primary, competitors[], gaps[] }
// Deterministic; same inputs => identical output. The `deltas[cat]` field is
// (competitor - primary) so a positive delta means the competitor is ahead.
// `gaps` lists categories where the primary trails the BEST reachable competitor
// by ≥ GAP_THRESHOLD; for performance, the response-time pair is attached too.
export function compareSites(primaryAudit, competitorAudits) {
  const primary = compactAudit(primaryAudit);
  const competitors = (Array.isArray(competitorAudits) ? competitorAudits : []).map((a) => {
    const c = compactAudit(a);
    const deltas = {};
    for (const cat of CATEGORIES) {
      const p = primary.scores[cat];
      const q = c.scores[cat];
      deltas[cat] = (Number.isFinite(p) && Number.isFinite(q)) ? (q - p) : null;
    }
    return { ...c, deltas };
  });

  const gaps = [];
  for (const cat of CATEGORIES) {
    const p = primary.scores[cat];
    if (!Number.isFinite(p)) continue;
    let bestScore = -Infinity;
    let bestComp = null;
    for (const c of competitors) {
      if (!c.ok) continue; // a blocked/failed competitor contributes no gap
      const q = c.scores[cat];
      if (Number.isFinite(q) && q > bestScore) { bestScore = q; bestComp = c; }
    }
    if (bestComp && (bestScore - p) >= GAP_THRESHOLD) {
      const gap = {
        category: cat,
        primary: p,
        best: bestScore,
        delta: bestScore - p,
        competitor: bestComp.url || bestComp.name,
      };
      // Performance also surfaces the response-time PAIR (the "loads in 5.0s vs
      // 1.8s" lede). Both numbers are real audit.metrics.responseMs values —
      // never synthesized — and we only attach the pair when BOTH are finite.
      if (cat === 'performance'
        && Number.isFinite(primary.metrics.responseMs)
        && Number.isFinite(bestComp.metrics.responseMs)) {
        gap.metric = {
          key: 'responseMs',
          primary: primary.metrics.responseMs,
          best: bestComp.metrics.responseMs,
        };
      }
      gaps.push(gap);
    }
  }
  // Stable sort: largest gap first, then category name for determinism.
  gaps.sort((a, b) => (b.delta - a.delta) || a.category.localeCompare(b.category));

  return { primary, competitors, gaps };
}

// probeCompetitors(urls, deps) -> array of audit objects (one per URL, in order).
// Each URL goes through the SAME SSRF-guarded probeUrl as the primary; a blocked
// hop yields an audit with `ok:false, status:"blocked by SSRF guard: ..."` so the
// renderer can call it out. NEVER throws on a failed competitor — only on the
// bounded-count contract violation (the caller must enforce the same cap upfront,
// this is defence in depth so the engine cannot be told to run 200 probes).
export async function probeCompetitors(urls, deps = {}) {
  if (!Array.isArray(urls)) return [];
  if (urls.length > MAX_COMPETITORS) {
    throw new Error(`too many competitors (${urls.length}) — max ${MAX_COMPETITORS}`);
  }
  const audits = [];
  let i = 0;
  for (const url of urls) {
    i += 1;
    const name = `competitor-${i}`;
    // eslint-disable-next-line no-await-in-loop
    audits.push(await probeUrl(name, url, deps));
  }
  return audits;
}

// ---------------------------------------------------------------------------
// Rendering — bilingual Markdown section (additive)
// ---------------------------------------------------------------------------
const fmtScore = (n) => (Number.isFinite(n) ? `${n}/100` : '—');
const fmtSign = (n) => (Number.isFinite(n) ? (n >= 0 ? `+${n}` : String(n)) : '—');

// Format milliseconds as a SECONDS figure to one decimal place — the value still
// traces back to the audit's measured responseMs (we never invent a quantity).
function fmtSeconds(ms) {
  if (!Number.isFinite(ms)) return '—';
  return (Math.round(ms / 100) / 10).toFixed(1);
}

export function renderCompetitorSection(comparison, opts = {}) {
  const loc = normLocale(opts.locale);
  const rtl = loc === 'ar';
  const CAT = rtl ? CAT_AR : CAT_EN;
  const c = comparison || {};
  const competitors = Array.isArray(c.competitors) ? c.competitors : [];
  if (!competitors.length) return '';

  const lines = [];
  lines.push(`## ${rtl ? 'مقارنة المنافسين' : 'Competitor comparison'}`);
  lines.push('');
  lines.push(rtl
    ? '_بيانات مأخوذة من فحوصات حقيقية للمنافسين الذين أدخلتهم يدويًا — لا يوجد تخمين._'
    : '_From real audits of the competitors you entered manually — no synthesis._');
  lines.push('');

  // Call out any blocked/failed competitor BEFORE the table so the reader sees
  // which one didn't get probed and why (non-leaky reason from the SSRF guard).
  const skipped = competitors.filter((x) => !x.ok);
  for (const cc of skipped) {
    const where = cc.url || cc.name || '?';
    const why = cc.blockedReason
      || (cc.status != null ? `HTTP ${cc.status}` : (rtl ? 'تعذّر الفحص' : 'fetch failed'));
    lines.push(rtl
      ? `- ⚠️ المنافس ${where}: لم يُفحص — ${why}.`
      : `- ⚠️ Competitor ${where}: not audited — ${why}.`);
  }
  if (skipped.length) lines.push('');

  // Side-by-side score table — primary column + one column per REACHABLE competitor.
  const reachable = competitors.filter((x) => x.ok);
  if (reachable.length) {
    const header = ['', rtl ? 'الفئة' : 'Category', rtl ? 'الموقع' : 'Primary'];
    for (const cc of reachable) header.push(cc.url || cc.name || '?');
    header.push('');
    lines.push(header.join(' | ').replace(/^ \| /, '| ').replace(/ \| $/, ' |'));
    const sep = ['', '---', '---'];
    for (const _ of reachable) sep.push('---');
    sep.push('');
    lines.push(sep.join('|'));
    for (const cat of CATEGORIES) {
      const p = (c.primary && c.primary.scores) ? c.primary.scores[cat] : undefined;
      const row = ['', CAT[cat] || cat, fmtScore(p)];
      for (const cc of reachable) {
        const q = cc.scores ? cc.scores[cat] : undefined;
        const d = (cc.deltas && cc.deltas[cat] != null) ? ` (${fmtSign(cc.deltas[cat])})` : '';
        row.push(`${fmtScore(q)}${d}`);
      }
      row.push('');
      lines.push(row.join(' | ').replace(/^ \| /, '| ').replace(/ \| $/, ' |'));
    }
    lines.push('');
  }

  // Key gaps — the headlines the operator can pitch. Every number is real.
  const gaps = Array.isArray(c.gaps) ? c.gaps : [];
  if (gaps.length) {
    lines.push(`**${rtl ? 'أبرز الفجوات' : 'Key gaps'}:**`);
    for (const g of gaps) {
      const cat = CAT[g.category] || g.category;
      if (g.metric && g.metric.key === 'responseMs'
        && Number.isFinite(g.metric.primary) && Number.isFinite(g.metric.best)) {
        // "loads in X.Xs vs Y.Ys" — both seconds from real audit.metrics.responseMs.
        const ps = fmtSeconds(g.metric.primary);
        const bs = fmtSeconds(g.metric.best);
        lines.push(rtl
          ? `- ${cat}: ${g.primary}/100 مقابل ${g.best}/100 (${g.competitor}). يُحمَّل في ${ps} ث مقابل ${bs} ث.`
          : `- ${cat}: ${g.primary}/100 vs ${g.best}/100 (${g.competitor}). Loads in ${ps}s vs ${bs}s.`);
      } else {
        lines.push(rtl
          ? `- ${cat}: ${g.primary}/100 مقابل ${g.best}/100 (${g.competitor}).`
          : `- ${cat}: ${g.primary}/100 vs ${g.best}/100 (${g.competitor}).`);
      }
    }
    lines.push('');
  } else if (reachable.length) {
    lines.push(rtl
      ? '_لا توجد فجوات ذات أثر مقارنة بالمنافسين الذين فُحصوا._'
      : '_No material gaps vs the competitors that were probed._');
    lines.push('');
  }

  return lines.join('\n');
}
