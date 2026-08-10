// pi-system SEO engine — deterministic category scoring + shared thresholds.
// ===========================================================================
// scoreAudit(audit) computes the four Lighthouse-STYLE category scores
// (performance, accessibility, best-practices, seo) PLUS a fifth, pi-system-only
// `security` category on a 0..100 scale from the probe's on-page checks, response
// headers, and basic metrics, using fixed, documented deductions. It is fully
// deterministic (same audit => same scores) so trends are comparable and the logic
// is unit-testable. When a richer engine (real Lighthouse) supplies its OWN category
// scores + Core Web Vitals, those are preferred and this is skipped (see
// lighthouse-adapter.js) — this scoring is the FREE default's fallback.
//
// The `security` score reuses securityScore() from security.js (the single source of
// truth for the header deductions + the matching findings), so a security score and a
// security finding never disagree — exactly as the four below mirror the rules engine.
//
// These thresholds are also the single source of truth the rules engine uses, so a
// finding ("LCP is poor") and a score never disagree.
// ===========================================================================

import { securityScore } from './security.js';

// Core Web Vitals / timing thresholds (industry-standard good | needs-improvement).
export const THRESHOLDS = {
  // server response time (probe's coarse TTFB proxy), milliseconds
  responseMs: { good: 800, poor: 1800 },
  // total HTML transfer size, bytes (very large HTML hurts performance)
  htmlBytes: { good: 100000, poor: 400000 },
  // Largest Contentful Paint, milliseconds (Lighthouse engine only)
  lcpMs: { good: 2500, poor: 4000 },
  // Cumulative Layout Shift, unitless (Lighthouse engine only)
  cls: { good: 0.1, poor: 0.25 },
  // Total Blocking Time, milliseconds (Lighthouse engine only)
  tbtMs: { good: 200, poor: 600 },
  // length guidance for SEO text fields
  titleLen: { min: 10, max: 60 },
  metaDescLen: { min: 50, max: 160 },
  // Browser-free PERFORMANCE signals the probe parses from the HTML (no Chromium).
  // render-blocking resources = blocking <script src> (not async/defer/module) +
  // <link rel=stylesheet> — each delays first paint.
  renderBlocking: { good: 3, poor: 8 },
  // approximate inline CSS+JS byte weight (ships on every page, never cacheable).
  inlineBytes: { good: 20000, poor: 60000 },
  // images present before we expect any below-the-fold image to use loading="lazy".
  lazyImagesMin: 3,
};

const clamp = (n) => Math.max(0, Math.min(100, Math.round(n)));

// Performance: from response time + HTML weight (the probe has no real CWV; the
// lighthouse adapter overrides this with Chromium-measured values when present).
function performanceScore(audit) {
  const m = audit.metrics || {};
  const c = audit.checks || {};
  let score = 100;
  const rt = Number(m.responseMs);
  if (Number.isFinite(rt)) {
    if (rt > THRESHOLDS.responseMs.poor) score -= 45;
    else if (rt > THRESHOLDS.responseMs.good) score -= 20;
  }
  const bytes = Number(m.htmlBytes);
  if (Number.isFinite(bytes) && bytes > 0) {
    if (bytes > THRESHOLDS.htmlBytes.poor) score -= 30;
    else if (bytes > THRESHOLDS.htmlBytes.good) score -= 12;
  }
  // Browser-free signals the probe parsed from the HTML (checks.performance). Only
  // applied when actually present — the Lighthouse adapter omits them and supplies its
  // own performance score (which overrides this one), so this never penalises it.
  const p = c.performance;
  if (p && typeof p === 'object') {
    const rb = Number(p.renderBlocking);
    if (Number.isFinite(rb)) {
      if (rb > THRESHOLDS.renderBlocking.poor) score -= 15;      // many blocking scripts/styles
      else if (rb > THRESHOLDS.renderBlocking.good) score -= 8;
    }
    const inline = Number(p.inlineBytes);
    if (Number.isFinite(inline)) {
      if (inline > THRESHOLDS.inlineBytes.poor) score -= 12;     // huge inline CSS/JS weight
      else if (inline > THRESHOLDS.inlineBytes.good) score -= 6;
    }
    // Several images but not one lazy-loaded -> the browser fetches them all up front.
    if ((Number(c.imagesTotal) || 0) >= THRESHOLDS.lazyImagesMin && (Number(p.lazyImages) || 0) === 0) {
      score -= 6;
    }
  }
  if (!audit.ok) score = 0;
  return clamp(score);
}

function accessibilityScore(audit) {
  const c = audit.checks || {};
  let score = 100;
  if (!c.lang) score -= 18;
  if ((c.h1?.count || 0) === 0) score -= 12;
  if (!c.viewport) score -= 12;
  const total = c.imagesTotal || 0;
  const missing = c.imagesMissingAlt || 0;
  if (total > 0 && missing > 0) score -= Math.min(35, Math.round((missing / total) * 35) + 5);
  if (!audit.ok) score = 0;
  return clamp(score);
}

function bestPracticesScore(audit) {
  const c = audit.checks || {};
  let score = 100;
  if (!c.https) score -= 40;
  if (!c.viewport) score -= 10;
  if (c.openGraph && !c.openGraph.image) score -= 5;
  if (!c.structuredData) score -= 5;
  if (!audit.ok) score = 0;
  return clamp(score);
}

function seoScore(audit) {
  const c = audit.checks || {};
  let score = 100;
  if (!c.title?.present) score -= 15;
  else if (c.title.length > THRESHOLDS.titleLen.max || c.title.length < THRESHOLDS.titleLen.min) score -= 4;
  if (!c.metaDescription?.present) score -= 12;
  else if (c.metaDescription.length > THRESHOLDS.metaDescLen.max) score -= 4;
  if ((c.h1?.count || 0) === 0) score -= 10;
  if (!c.canonical) score -= 8;
  if (c.sitemapXml === false) score -= 10;
  if (c.robotsTxt === false) score -= 5;
  if (!c.lang) score -= 6;
  const og = c.openGraph || {};
  if (!og.title) score -= 3;
  if (!og.description) score -= 3;
  if (!og.image) score -= 3;
  if (!c.structuredData) score -= 4;
  if (!audit.ok) score = 0;
  return clamp(score);
}

// Security: 0..100 from the response-header checks the probe stored at
// checks.security (securityScore() owns the deductions). An unreachable/failed audit
// scores 0, matching the four categories above (we never saw real headers to judge).
function securityCategoryScore(audit) {
  if (!audit.ok) return 0;
  return securityScore((audit.checks || {}).security);
}

export function scoreAudit(audit) {
  return {
    performance: performanceScore(audit),
    accessibility: accessibilityScore(audit),
    'best-practices': bestPracticesScore(audit),
    seo: seoScore(audit),
    security: securityCategoryScore(audit),
  };
}

// Map a numeric metric to a coarse rating using a THRESHOLDS entry.
export function rate(value, t, lowerIsBetter = true) {
  if (!Number.isFinite(value) || !t) return 'unknown';
  if (lowerIsBetter) {
    if (value <= t.good) return 'good';
    if (value <= t.poor) return 'needs-improvement';
    return 'poor';
  }
  if (value >= t.good) return 'good';
  if (value >= t.poor) return 'needs-improvement';
  return 'poor';
}
