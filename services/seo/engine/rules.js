// pi-system SEO engine — the deterministic, FREE recommendations engine.
// ===========================================================================
// analyze(audit) turns an audit object (from the probe or the Lighthouse adapter)
// into a clear, PRIORITIZED list of actionable recommendations using fixed rules —
// NO API, NO AI, NO network. This is the default path: it always produces a sane
// report. The optional AI enrichment (ai.js) only ever ADDS to this output and is
// inert unless AI_PROVIDER + AI_API_KEY are set.
//
// Each finding: { id, priority, category, title, detail, recommendation }.
//   priority ∈ critical | high | medium | low  (sorted critical-first, stable).
//   category ∈ performance | accessibility | best-practices | seo | security
// Pure: same audit => same ordered findings, so the tests can assert exact output.
//
// The `security` findings come from security.js (securityFindings), derived from the
// probe's response headers (audit.checks.security). They are appended here and run
// through the SAME sortFindings, so a critical "no HTTPS" security finding sorts to the
// top alongside the other criticals — one prioritised list across all five categories.
// ===========================================================================

import { THRESHOLDS, rate } from './scoring.js';
import { securityFindings } from './security.js';

const PRIORITY_WEIGHT = { critical: 0, high: 1, medium: 2, low: 3 };

// Helper to build a finding with a stable shape.
function f(id, priority, category, title, detail, recommendation) {
  return { id, priority, category, title, detail, recommendation };
}

export function analyze(audit) {
  const out = [];
  const c = (audit && audit.checks) || {};
  const m = (audit && audit.metrics) || {};
  const s = (audit && audit.scores) || {};

  // --- Reachability (most critical) ----------------------------------------
  if (audit && audit.ok === false) {
    out.push(f(
      'site-unreachable', 'critical', 'best-practices',
      'The site did not return a successful page',
      `The probe got ${audit.status ? 'HTTP ' + audit.status : 'no response'} for ${audit.url}.`,
      'Confirm the site is deployed and reachable at this URL (DNS, Caddy route, the container is up) before reading the other findings.',
    ));
    // No HTML to inspect — return the single actionable finding.
    return sortFindings(out);
  }

  // --- Transport ------------------------------------------------------------
  if (c.https === false) {
    out.push(f(
      'no-https', 'critical', 'best-practices',
      'Serve the site over HTTPS',
      'The audited URL is not HTTPS. Search engines penalise non-secure pages and browsers mark them "Not secure".',
      'Front the site with Caddy (it issues certificates automatically) and audit the https:// URL.',
    ));
  }

  // --- Title ----------------------------------------------------------------
  if (!c.title || !c.title.present) {
    out.push(f(
      'title-missing', 'high', 'seo',
      'Add a <title> tag',
      'The page has no title. The title is the single most important on-page SEO signal and is what shows in search results and browser tabs.',
      'Set a unique, descriptive <title> per page (use the seo-toolkit buildMetadata helper).',
    ));
  } else if (c.title.length > THRESHOLDS.titleLen.max) {
    out.push(f(
      'title-too-long', 'low', 'seo',
      'Shorten the page title',
      `The title is ${c.title.length} characters; search engines truncate around ${THRESHOLDS.titleLen.max}.`,
      `Trim the title to ≤ ${THRESHOLDS.titleLen.max} characters, front-loading the most important words.`,
    ));
  } else if (c.title.length < THRESHOLDS.titleLen.min) {
    out.push(f(
      'title-too-short', 'medium', 'seo',
      'Make the title more descriptive',
      `The title is only ${c.title.length} characters — likely too thin to describe the page.`,
      `Expand the title to roughly ${THRESHOLDS.titleLen.min}-${THRESHOLDS.titleLen.max} characters.`,
    ));
  }

  // --- Meta description -----------------------------------------------------
  if (!c.metaDescription || !c.metaDescription.present) {
    out.push(f(
      'meta-description-missing', 'high', 'seo',
      'Add a meta description',
      'The page has no meta description, so search engines invent the snippet shown under your result — costing you click-through control.',
      `Add a compelling meta description of ~${THRESHOLDS.metaDescLen.min}-${THRESHOLDS.metaDescLen.max} characters per page.`,
    ));
  } else if (c.metaDescription.length > THRESHOLDS.metaDescLen.max) {
    out.push(f(
      'meta-description-too-long', 'low', 'seo',
      'Shorten the meta description',
      `The meta description is ${c.metaDescription.length} characters; it is truncated past ~${THRESHOLDS.metaDescLen.max}.`,
      `Trim it to ≤ ${THRESHOLDS.metaDescLen.max} characters.`,
    ));
  }

  // --- Headings -------------------------------------------------------------
  const h1 = (c.h1 && c.h1.count) || 0;
  if (h1 === 0) {
    out.push(f(
      'h1-missing', 'high', 'accessibility',
      'Add exactly one <h1>',
      'The page has no <h1>. A single, descriptive top-level heading helps both screen readers and search engines understand the page.',
      'Add one <h1> describing the page; use <h2>..<h6> for the hierarchy below it.',
    ));
  } else if (h1 > 1) {
    out.push(f(
      'h1-multiple', 'low', 'accessibility',
      'Use a single <h1> per page',
      `The page has ${h1} <h1> elements; a single top-level heading is clearer for assistive tech and crawlers.`,
      'Demote the extra <h1> elements to <h2> and keep one <h1>.',
    ));
  }

  // --- Mobile viewport ------------------------------------------------------
  if (c.viewport === false) {
    out.push(f(
      'viewport-missing', 'high', 'best-practices',
      'Add a responsive viewport meta tag',
      'No <meta name="viewport"> was found, so the page will not scale on phones — most traffic is mobile, and Google indexes mobile-first.',
      'Add <meta name="viewport" content="width=device-width, initial-scale=1">.',
    ));
  }

  // --- Language / direction -------------------------------------------------
  if (!c.lang) {
    out.push(f(
      'lang-missing', 'medium', 'accessibility',
      'Set the <html lang> attribute',
      'The <html> element has no lang attribute, so screen readers and search engines cannot tell which language the page is in.',
      'Set <html lang="ar" dir="rtl"> (or "en"/"ltr"). The i18n-bilingual module does this per request automatically.',
    ));
  }

  // --- Canonical ------------------------------------------------------------
  if (c.canonical === false) {
    out.push(f(
      'canonical-missing', 'medium', 'seo',
      'Add a canonical URL',
      'No canonical link was found. Without it, duplicate or parameterised URLs can split your ranking signals.',
      'Emit <link rel="canonical"> per page (seo-toolkit buildMetadata sets alternates.canonical).',
    ));
  }

  // --- Open Graph / social --------------------------------------------------
  const og = c.openGraph || {};
  const ogMissing = ['title', 'description', 'image'].filter((k) => og[k] === false || og[k] === undefined);
  if (ogMissing.length > 0) {
    out.push(f(
      'open-graph-incomplete', 'medium', 'seo',
      'Complete Open Graph tags for rich link previews',
      `Missing Open Graph tag(s): ${ogMissing.map((k) => 'og:' + k).join(', ')}. These control how the page looks when shared on WhatsApp / social.`,
      'Add og:title, og:description and og:image (1200×630). seo-toolkit buildMetadata emits the openGraph block.',
    ));
  }

  // --- Image alt text -------------------------------------------------------
  const total = c.imagesTotal || 0;
  const missing = c.imagesMissingAlt || 0;
  if (total > 0 && missing > 0) {
    const many = missing / total >= 0.5;
    out.push(f(
      'images-missing-alt', many ? 'high' : 'medium', 'accessibility',
      'Add alt text to images',
      `${missing} of ${total} images have no alt text — invisible to screen readers and to image search.`,
      'Give every meaningful <img> a concise alt describing it; use alt="" only for decorative images.',
    ));
  }

  // --- Crawlability: robots.txt + sitemap.xml -------------------------------
  if (c.sitemapXml === false) {
    out.push(f(
      'sitemap-missing', 'high', 'seo',
      'Publish a sitemap.xml',
      'No /sitemap.xml was reachable. A sitemap helps search engines discover every page (and every locale).',
      'Add the seo-toolkit app/sitemap.js (bilingual-aware) and submit it in Search Console / Bing Webmaster Tools.',
    ));
  }
  if (c.robotsTxt === false) {
    out.push(f(
      'robots-missing', 'medium', 'seo',
      'Publish a robots.txt',
      'No /robots.txt was reachable. It tells crawlers what to index and points them at your sitemap.',
      'Add the seo-toolkit app/robots.js (it references the sitemap automatically).',
    ));
  }

  // --- Structured data ------------------------------------------------------
  if (c.structuredData === false) {
    out.push(f(
      'structured-data-missing', 'low', 'seo',
      'Add structured data (JSON-LD)',
      'No JSON-LD structured data was found. Schema.org markup can earn rich results (ratings, breadcrumbs, business info).',
      'Add the seo-toolkit StructuredData component (Organization / WebSite scaffolding).',
    ));
  }

  // --- Performance: response time + page weight -----------------------------
  const rt = Number(m.responseMs);
  if (Number.isFinite(rt)) {
    const r = rate(rt, THRESHOLDS.responseMs);
    if (r === 'poor') {
      out.push(f(
        'response-time-poor', 'high', 'performance',
        'Reduce server response time',
        `The server took ${rt} ms to respond (poor is > ${THRESHOLDS.responseMs.poor} ms). Slow responses hurt rankings and bounce rate.`,
        'Enable caching/compression at Caddy, render static where possible, and check the container is not memory-starved on the Pi.',
      ));
    } else if (r === 'needs-improvement') {
      out.push(f(
        'response-time-slow', 'medium', 'performance',
        'Improve server response time',
        `The server took ${rt} ms to respond (good is ≤ ${THRESHOLDS.responseMs.good} ms).`,
        'Cache responses, reduce work per request, and keep the database query path lean.',
      ));
    }
  }
  const bytes = Number(m.htmlBytes);
  if (Number.isFinite(bytes) && bytes > THRESHOLDS.htmlBytes.poor) {
    out.push(f(
      'html-too-large', 'medium', 'performance',
      'Reduce the HTML payload',
      `The HTML document is ${Math.round(bytes / 1024)} KB (large is > ${Math.round(THRESHOLDS.htmlBytes.poor / 1024)} KB).`,
      'Trim inlined data/markup, defer non-critical content, and lean on Caddy compression (already enabled).',
    ));
  }

  // --- Browser-free performance signals (probe engine; parsed from the HTML) -
  // Only when the probe actually parsed them (checks.performance present); the
  // Lighthouse engine omits these and raises its own Core Web Vitals findings below.
  const p = c.performance;
  if (p && typeof p === 'object') {
    const rb = Number(p.renderBlocking);
    if (Number.isFinite(rb) && rb > THRESHOLDS.renderBlocking.good) {
      out.push(f(
        'render-blocking-resources', rb > THRESHOLDS.renderBlocking.poor ? 'high' : 'medium', 'performance',
        'Reduce render-blocking resources',
        `The page loads ${rb} render-blocking resource(s) — blocking <script src> plus stylesheets (good is ≤ ${THRESHOLDS.renderBlocking.good}). Each one delays first paint.`,
        'Add defer/async to non-critical scripts (or type="module"), combine and trim CSS, and inline only the critical styles.',
      ));
    }
    const inlineBytes = Number(p.inlineBytes);
    if (Number.isFinite(inlineBytes) && inlineBytes > THRESHOLDS.inlineBytes.poor) {
      out.push(f(
        'inline-assets-large', 'medium', 'performance',
        'Move large inline CSS/JS into cacheable files',
        `About ${Math.round(inlineBytes / 1024)} KB of CSS/JS is inlined in the HTML (large is > ${Math.round(THRESHOLDS.inlineBytes.poor / 1024)} KB). Inlined bytes ship on every page and can never be cached.`,
        'Extract big inline <style>/<script> blocks into external files the browser can cache across visits.',
      ));
    }
    const noDims = Number(p.imagesMissingDimensions);
    if (Number.isFinite(noDims) && noDims > 0) {
      out.push(f(
        'images-missing-dimensions', 'medium', 'performance',
        'Set width and height on images to stop layout shift',
        `${noDims} image(s) have no width/height, so content jumps as they load — a poor Cumulative Layout Shift, which Google measures and ranks on.`,
        'Add width and height attributes (or a CSS aspect-ratio) to every <img> so the browser reserves the space up front.',
      ));
    }
    const imgsTotal = Number(c.imagesTotal) || 0;
    if (imgsTotal >= THRESHOLDS.lazyImagesMin && (Number(p.lazyImages) || 0) === 0) {
      out.push(f(
        'images-not-lazy', 'low', 'performance',
        'Lazy-load below-the-fold images',
        `The page has ${imgsTotal} images and none use loading="lazy", so the browser downloads them all immediately — slow on phones and mobile data.`,
        'Add loading="lazy" to images that start off-screen (leave it OFF the main hero/LCP image).',
      ));
    }
    if (Number.isFinite(rb) && rb > THRESHOLDS.renderBlocking.good && p.resourceHints === false) {
      out.push(f(
        'resource-hints-missing', 'low', 'performance',
        'Add resource hints (preconnect / preload)',
        'The page pulls several external resources but uses no <link rel="preconnect"> or <link rel="preload">, so the browser connects to them late.',
        'preconnect to the origins of critical third-party assets and preload your most important font, stylesheet, or hero image.',
      ));
    }
  }

  // --- Core Web Vitals (only present from the Lighthouse engine) ------------
  cwv(out, 'lcp-poor', m.lcpMs, THRESHOLDS.lcpMs, 'Largest Contentful Paint', 'ms',
    'Optimise the largest above-the-fold element (image/text): preload it, size images, cut render-blocking CSS/JS.');
  cwv(out, 'cls-poor', m.cls, THRESHOLDS.cls, 'Cumulative Layout Shift', '',
    'Reserve space for images/ads/embeds (set width/height) so content does not jump as it loads.');
  cwv(out, 'tbt-poor', m.tbtMs, THRESHOLDS.tbtMs, 'Total Blocking Time', 'ms',
    'Split long JavaScript tasks, defer non-critical scripts, and ship less client JS.');

  // --- Security (HTTP response-header hardening) ----------------------------
  // Client-facing trust/security findings derived from the probe's response headers
  // (audit.checks.security). Returns [] when no headers were recorded (e.g. an
  // unreachable site or a fixture without a security block), so this is a clean no-op
  // for header-less audits; sortFindings below re-orders everything critical-first.
  out.push(...securityFindings(audit));

  // --- Low category scores (a safety net catch-all) -------------------------
  for (const cat of ['performance', 'accessibility', 'best-practices', 'seo']) {
    const score = s[cat];
    if (Number.isFinite(score) && score < 50 && !out.some((x) => x.category === cat && x.priority === 'high')) {
      out.push(f(
        `low-score-${cat}`, 'high', cat,
        `Improve the ${cat} score`,
        `The ${cat} category scored ${score}/100 overall.`,
        `Address the ${cat} findings above; re-run the audit to confirm the score recovers.`,
      ));
    }
  }

  return sortFindings(out);
}

// Add a Core Web Vitals finding when the metric is present and not "good".
function cwv(out, id, value, t, label, unit, recommendation) {
  const v = Number(value);
  if (!Number.isFinite(v)) return; // metric absent (probe engine) — skip cleanly.
  const r = rate(v, t);
  if (r === 'good') return;
  out.push(f(
    id, r === 'poor' ? 'high' : 'medium', 'performance',
    `Improve ${label}`,
    `${label} is ${v}${unit} (${r}; good is ≤ ${t.good}${unit}).`,
    recommendation,
  ));
}

// Stable sort: by priority weight, then category, then id — so output is deterministic.
export function sortFindings(findings) {
  return findings
    .map((x, i) => ({ x, i }))
    .sort((a, b) => {
      const pw = PRIORITY_WEIGHT[a.x.priority] - PRIORITY_WEIGHT[b.x.priority];
      if (pw !== 0) return pw;
      if (a.x.category !== b.x.category) return a.x.category < b.x.category ? -1 : 1;
      if (a.x.id !== b.x.id) return a.x.id < b.x.id ? -1 : 1;
      return a.i - b.i;
    })
    .map((w) => w.x);
}

// Convenience: count findings by priority (used by the report + notifier summary).
export function summarize(findings) {
  const counts = { critical: 0, high: 0, medium: 0, low: 0 };
  for (const x of findings) if (counts[x.priority] !== undefined) counts[x.priority] += 1;
  return counts;
}
