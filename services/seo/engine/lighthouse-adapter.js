// pi-system SEO engine — Lighthouse result adapter (OPTIONAL heavy engine).
// ===========================================================================
// Maps a real Lighthouse JSON result into the SAME audit object the probe produces,
// so the store / rules / report code is identical for both engines. Lighthouse runs
// headless Chromium and is HEAVY on a Pi (see services/seo/README.md) — it is the
// opt-in engine (`./scripts/seo.sh audit <site> --engine lighthouse`), never the
// default. This adapter is pure: it takes a parsed Lighthouse report object and
// returns our audit shape, preferring Lighthouse's OWN category scores + Core Web
// Vitals (so rules.js raises real LCP/CLS/TBT findings) over the probe's heuristics.
// ===========================================================================

import { buildAudit } from './probe.js';
import { computeVerdict } from './verdict.js';

// 0..1 (Lighthouse) -> 0..100 (ours). null-safe.
function pct(v) {
  return Number.isFinite(v) ? Math.round(v * 100) : null;
}
function audMs(audits, id) {
  const v = audits?.[id]?.numericValue;
  return Number.isFinite(v) ? Math.round(v) : null;
}
function audNum(audits, id) {
  const v = audits?.[id]?.numericValue;
  return Number.isFinite(v) ? v : null;
}
function passed(audits, id) {
  // Lighthouse boolean-ish audits score 1 when they pass.
  const s = audits?.[id]?.score;
  return s === 1 || s === true;
}

export function fromLighthouse(lhr, { name, url, timestamp }) {
  const cats = lhr?.categories || {};
  const audits = lhr?.audits || {};

  const scores = {
    performance: pct(cats.performance?.score),
    accessibility: pct(cats.accessibility?.score),
    'best-practices': pct(cats['best-practices']?.score),
    seo: pct(cats.seo?.score),
  };

  const metrics = {
    responseMs: audMs(audits, 'server-response-time'),
    lcpMs: audMs(audits, 'largest-contentful-paint'),
    fcpMs: audMs(audits, 'first-contentful-paint'),
    tbtMs: audMs(audits, 'total-blocking-time'),
    cls: audNum(audits, 'cumulative-layout-shift'),
    requests: lhr?.audits?.['network-requests']?.details?.items?.length ?? null,
  };

  // Translate the on-page audits Lighthouse already runs into our checks shape, so
  // the rule-based engine adds the same actionable findings on top of CWV.
  const checks = {
    https: passed(audits, 'is-on-https') || /^https:/i.test(url),
    title: { present: passed(audits, 'document-title'), length: null },
    metaDescription: { present: passed(audits, 'meta-description'), length: null },
    h1: { count: passed(audits, 'heading-order') ? 1 : 1 }, // LH has no h1 count; assume present
    viewport: passed(audits, 'viewport'),
    lang: passed(audits, 'html-has-lang') ? 'set' : null,
    canonical: passed(audits, 'canonical'),
    openGraph: { title: undefined, description: undefined, image: undefined },
    imagesTotal: 0,
    imagesMissingAlt: passed(audits, 'image-alt') ? 0 : 1,
    structuredData: passed(audits, 'structured-data'),
    robotsTxt: passed(audits, 'robots-txt'),
    sitemapXml: null, // Lighthouse doesn't probe sitemap.xml directly.
  };

  const audit = buildAudit({
    name,
    url,
    engine: 'lighthouse',
    timestamp,
    ok: true,
    status: 200,
    metrics,
    checks,
  });
  // Prefer Lighthouse's own category scores over our heuristic ones when present.
  for (const k of Object.keys(scores)) {
    if (Number.isFinite(scores[k])) audit.scores[k] = scores[k];
  }
  // buildAudit already attached a verdict, but it was computed from the probe's
  // heuristic scores — recompute it now over Lighthouse's final scores.
  audit.verdict = computeVerdict(audit);
  return audit;
}
