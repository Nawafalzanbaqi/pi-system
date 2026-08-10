// pi-system SEO engine — the RE-AUDIT diff engine (pure, offline).
// ===========================================================================
// Turns the one-shot auditor into an ongoing MONITORING signal: given a site's
// PREVIOUS audit and its CURRENT one, work out what actually CHANGED. The audit
// history already exists as append-only JSONL in the store (data/seo/audits/
// <name>.jsonl), so callers read the last two rows and hand them here.
//
//   diffAudits(previous, current) -> a deterministic, structured delta:
//     { baseline, reachability, wentOffline, recovered,
//       overall:{previous,current,delta,direction},
//       tier:{previous,current,changed,direction}, tierDropped,
//       scores:{ <category>:{previous,current,delta,direction} },
//       findings:{ resolved:[…], new:[…], persisting:[…] },   // {id,priority,category,title}
//       hasNewCritical, hasNewHigh }
//
//   summarizeDiff(delta, {locale}) -> a bilingual (ar/en) one-paragraph
//     "what changed since last time"; CRITICAL REGRESSIONS LEAD.
//
//   isMeaningfulChange(delta) -> true when a re-audit warrants an OPERATOR alert
//     (a NEW critical/high finding, a tier drop, or the site going offline).
//
// PURE + DETERMINISTIC: no I/O, no clock, no network — same pair in => same delta
// out, so it is unit-tested offline against fixture pairs (tests/seo/run.sh). It
// honours a pre-attached audit.verdict / audit.findings or derives them from the
// SAME engine (verdict.js / rules.js), so it needs nothing but the two audits.
// ===========================================================================

import { analyze, sortFindings } from './rules.js';
import { computeVerdict } from './verdict.js';

// The five categories, in client-facing importance order (matches report.js).
const DIFF_CATEGORIES = ['seo', 'performance', 'security', 'best-practices', 'accessibility'];
const TIER_RANK = { poor: 0, fair: 1, good: 2, excellent: 3 };

// Localized category names (ar first — the platform default) for summarizeDiff.
const CAT_WORD = {
  ar: {
    seo: 'تحسين محركات البحث', performance: 'الأداء', security: 'الأمان',
    'best-practices': 'أفضل الممارسات', accessibility: 'سهولة الوصول',
  },
  en: {
    seo: 'SEO', performance: 'Performance', security: 'Security',
    'best-practices': 'Best practices', accessibility: 'Accessibility',
  },
};
const TIER_WORD = {
  ar: { excellent: 'ممتاز', good: 'جيد', fair: 'مقبول', poor: 'ضعيف' },
  en: { excellent: 'excellent', good: 'good', fair: 'fair', poor: 'poor' },
};
const PRIO_WORD = {
  ar: { critical: 'حرجة', high: 'عالية', medium: 'متوسطة', low: 'منخفضة' },
  en: { critical: 'critical', high: 'high', medium: 'medium', low: 'low' },
};

function normLocale(locale) {
  return String(locale || '').trim().toLowerCase().startsWith('en') ? 'en' : 'ar';
}

// Direction of a numeric change: up (>0) / down (<0) / same (0 or not comparable).
function dirOf(delta) {
  if (!Number.isFinite(delta) || delta === 0) return 'same';
  return delta > 0 ? 'up' : 'down';
}

// Trim a finding to the fields a change-summary actually needs.
const compactFinding = (x) => ({ id: x.id, priority: x.priority, category: x.category, title: x.title });

// Honour a pre-attached verdict/findings, else derive them (pure, deterministic).
function verdictOf(a) {
  return (a && a.verdict && typeof a.verdict === 'object') ? a.verdict : computeVerdict(a || {});
}
function findingsOf(a) {
  return sortFindings(Array.isArray(a && a.findings) ? a.findings : analyze(a || {}));
}

export function diffAudits(previous, current) {
  const cur = current || {};
  const cv = verdictOf(cur);

  // --- BASELINE: no previous audit -> first run, nothing to compare. ---------
  if (!previous) {
    return {
      baseline: true,
      reachability: cur.ok === false ? 'unreachable' : 'reachable',
      wentOffline: false,
      recovered: false,
      overall: { previous: null, current: cv.overall ?? null, delta: null, direction: 'same' },
      tier: { previous: null, current: cv.tier || null, changed: false, direction: 'same' },
      tierDropped: false,
      scores: {},
      findings: { resolved: [], new: [], persisting: [] },
      hasNewCritical: false,
      hasNewHigh: false,
    };
  }

  const prev = previous;
  const pv = verdictOf(prev);
  const pOk = prev.ok !== false;
  const cOk = cur.ok !== false;

  // --- Reachability transition (a regression to offline is flagged critical). -
  let reachability;
  if (pOk && cOk) reachability = 'reachable';
  else if (!pOk && cOk) reachability = 'recovered';
  else if (pOk && !cOk) reachability = 'regressed';
  else reachability = 'unreachable'; // both runs unreachable

  // --- Per-category score change (union of categories present in either run). -
  const scores = {};
  const ps = prev.scores || {};
  const cs = cur.scores || {};
  for (const c of DIFF_CATEGORIES) {
    const a = Number(ps[c]);
    const b = Number(cs[c]);
    const aF = Number.isFinite(a);
    const bF = Number.isFinite(b);
    if (!aF && !bF) continue;
    const delta = aF && bF ? b - a : null;
    scores[c] = { previous: aF ? a : null, current: bF ? b : null, delta, direction: dirOf(delta) };
  }

  // --- Overall score + tier change. -----------------------------------------
  const oDelta = Number.isFinite(pv.overall) && Number.isFinite(cv.overall) ? cv.overall - pv.overall : null;
  const overall = {
    previous: Number.isFinite(pv.overall) ? pv.overall : null,
    current: Number.isFinite(cv.overall) ? cv.overall : null,
    delta: oDelta,
    direction: dirOf(oDelta),
  };
  const tRank = TIER_RANK[cv.tier] - TIER_RANK[pv.tier];
  const tier = {
    previous: pv.tier || null,
    current: cv.tier || null,
    changed: pv.tier !== cv.tier,
    direction: dirOf(Number.isFinite(tRank) ? tRank : 0),
  };

  // --- Findings delta, compared by stable id. -------------------------------
  const pf = findingsOf(prev);
  const cf = findingsOf(cur);
  const pIds = new Set(pf.map((x) => x.id));
  const cIds = new Set(cf.map((x) => x.id));
  const resolved = pf.filter((x) => !cIds.has(x.id)).map(compactFinding); // in previous, gone now
  const neu = cf.filter((x) => !pIds.has(x.id)).map(compactFinding); // appeared this run
  const persisting = cf.filter((x) => pIds.has(x.id)).map(compactFinding); // present in both

  return {
    baseline: false,
    reachability,
    wentOffline: reachability === 'regressed',
    recovered: reachability === 'recovered',
    overall,
    tier,
    tierDropped: tier.direction === 'down',
    scores,
    findings: { resolved, new: neu, persisting },
    hasNewCritical: neu.some((x) => x.priority === 'critical'),
    hasNewHigh: neu.some((x) => x.priority === 'high'),
  };
}

// isMeaningfulChange(delta) -> should a re-audit push an OPERATOR heads-up? True on
// a regression worth waking the operator for: the site went offline, a NEW critical
// or high finding appeared, or the overall tier dropped. A baseline (first run) and
// pure improvements/recoveries are NOT alert-worthy (they still show in the report).
export function isMeaningfulChange(delta) {
  if (!delta || delta.baseline) return false;
  if (delta.wentOffline) return true;
  if (delta.hasNewCritical || delta.hasNewHigh) return true;
  if (delta.tierDropped) return true;
  return false;
}

// Count new findings by priority (criticals + highs lead the summary/alert).
function newByPriority(delta) {
  const out = { critical: 0, high: 0, medium: 0, low: 0 };
  for (const x of (delta.findings && delta.findings.new) || []) {
    if (out[x.priority] !== undefined) out[x.priority] += 1;
  }
  return out;
}

// If every resolved finding shares one category, name it; else null.
function commonCategory(list) {
  if (!list.length) return null;
  const first = list[0].category;
  return list.every((x) => x.category === first) ? first : null;
}

// summarizeDiff(delta, {locale}) -> ONE plain-language paragraph describing what
// changed since the previous audit, bilingual (ar default / en). CRITICAL
// REGRESSIONS LEAD: an offline regression, then new criticals/highs, then the
// overall/tier move, then notable category moves, then resolved issues. Pure.
export function summarizeDiff(delta, opts = {}) {
  const loc = normLocale(opts.locale);
  const d = delta || {};
  const cat = (c) => CAT_WORD[loc][c] || c;
  const tw = (t) => TIER_WORD[loc][t] || t;
  const pw = (p) => PRIO_WORD[loc][p] || p;

  if (d.baseline) {
    return loc === 'ar'
      ? 'هذا أول فحص — تم تسجيل النتيجة كخط أساس؛ لا يوجد فحص سابق للمقارنة به.'
      : 'First audit — baseline recorded; there is nothing previous to compare against yet.';
  }

  const clauses = [];

  // 1) Reachability regression LEADS (the most critical change).
  if (d.wentOffline) {
    clauses.push(loc === 'ar'
      ? '⚠️ أصبح الموقع غير متاح منذ آخر فحص (كان يعمل سابقًا)'
      : '⚠️ the site went OFFLINE since the last audit (it was reachable before)');
  } else if (d.recovered) {
    clauses.push(loc === 'ar'
      ? 'عاد الموقع للعمل منذ آخر فحص'
      : 'the site is back online since the last audit');
  }

  // 2) NEW critical/high findings next (the headline regressions).
  const nb = newByPriority(d);
  const newCrit = (d.findings && d.findings.new || []).filter((x) => x.priority === 'critical');
  if (nb.critical > 0) {
    if (nb.critical === 1) {
      clauses.push(loc === 'ar'
        ? `ظهرت ملاحظة حرجة جديدة في فئة ${cat(newCrit[0].category)}`
        : `a new critical ${cat(newCrit[0].category)} issue appeared`);
    } else {
      clauses.push(loc === 'ar'
        ? `ظهرت ${nb.critical} ملاحظات حرجة جديدة`
        : `${nb.critical} new critical issues appeared`);
    }
  }
  if (nb.high > 0) {
    clauses.push(loc === 'ar'
      ? `${nb.high} ملاحظة عالية الأولوية جديدة`
      : `${nb.high} new high-priority issue${nb.high > 1 ? 's' : ''}`);
  }

  // 3) Overall score + tier movement (skip on a still-offline run with no numbers).
  if (Number.isFinite(d.overall && d.overall.delta) && d.overall.delta !== 0) {
    const verb = d.overall.direction === 'up'
      ? (loc === 'ar' ? 'تحسّنت' : 'improved')
      : (loc === 'ar' ? 'تراجعت' : 'declined');
    const tierPart = (d.tier && d.tier.changed)
      ? ` (${tw(d.tier.previous)}→${tw(d.tier.current)})`
      : '';
    clauses.push(loc === 'ar'
      ? `${verb} النتيجة الإجمالية ${d.overall.previous}→${d.overall.current}${tierPart}`
      : `overall score ${verb} ${d.overall.previous}→${d.overall.current}${tierPart}`);
  } else if (d.tier && d.tier.changed) {
    clauses.push(loc === 'ar'
      ? `تغيّر التقييم من ${tw(d.tier.previous)} إلى ${tw(d.tier.current)}`
      : `tier changed ${tw(d.tier.previous)}→${tw(d.tier.current)}`);
  }

  // 4) Notable per-category moves (biggest absolute change first, up to two).
  const movers = Object.entries(d.scores || {})
    .filter(([, v]) => Number.isFinite(v.delta) && v.delta !== 0)
    .sort((a, b) => Math.abs(b[1].delta) - Math.abs(a[1].delta))
    .slice(0, 2);
  for (const [c, v] of movers) {
    const verb = v.direction === 'up'
      ? (loc === 'ar' ? 'ارتفع' : 'improved')
      : (loc === 'ar' ? 'انخفض' : 'dropped');
    clauses.push(loc === 'ar'
      ? `${cat(c)} ${verb} ${v.previous}→${v.current}`
      : `${cat(c)} ${verb} ${v.previous}→${v.current}`);
  }

  // 5) Resolved issues last (the good news).
  const resolved = (d.findings && d.findings.resolved) || [];
  if (resolved.length > 0) {
    const cc = commonCategory(resolved);
    if (cc) {
      clauses.push(loc === 'ar'
        ? `تم حل ${resolved.length} ملاحظة في فئة ${cat(cc)}`
        : `${resolved.length} ${cat(cc)} issue${resolved.length > 1 ? 's were' : ' was'} resolved`);
    } else {
      clauses.push(loc === 'ar'
        ? `تم حل ${resolved.length} ملاحظة`
        : `${resolved.length} issue${resolved.length > 1 ? 's were' : ' was'} resolved`);
    }
  }

  if (clauses.length === 0) {
    return loc === 'ar'
      ? 'لا تغييرات جوهرية منذ آخر فحص — النتائج والملاحظات ثابتة.'
      : 'No material changes since the last audit — scores and findings are unchanged.';
  }

  // Join into one paragraph; capitalize the first character (en) and end with a stop.
  let s = clauses.join(loc === 'ar' ? '؛ ' : '; ');
  if (loc === 'en') s = s.charAt(0).toUpperCase() + s.slice(1);
  s += loc === 'ar' ? '.' : '.';
  return s;
}
