// pi-system SEO engine — the lightweight, FREE, deterministic audit probe.
// ===========================================================================
// WHY a probe and not always-on Lighthouse/Chromium (see services/seo/README.md):
// headless Chromium is heavy on a Pi 5 (hundreds of MB of RAM + real CPU per run),
// so the DEFAULT engine here is a pure-Node HTTP probe with NO browser: it fetches
// each page once over HTTP, parses the HTML deterministically, runs the on-page
// SEO / accessibility / best-practice checks, measures basic timing/size metrics,
// and computes Lighthouse-STYLE category scores from documented rules. It is free,
// needs no credentials, is trivially ARM64-safe, and — being pure logic — is unit
// tested without Docker, network, or a browser. The heavier REAL Lighthouse engine
// stays available as an opt-in (lighthouse-adapter.js), never the default.
//
// Everything here is PURE and DEPENDENCY-FREE. The only side-effect (a network
// fetch) is isolated in probeUrl(), behind an injectable `fetchImpl`, so the HTML
// analysis (analyzeHtml) can be tested against fixture HTML with no network.
// ===========================================================================

import { scoreAudit } from './scoring.js';
import { computeVerdict } from './verdict.js';
import { analyzeSecurity } from './security.js';
import { assertUrlAllowed } from './ssrf-guard.js';

// --- Tiny, dependency-free HTML helpers ------------------------------------
// Deliberately simple, deterministic regex extraction — enough for on-page SEO
// signals (title, meta, headings, lang, canonical, Open Graph, alt text). It is
// NOT a full HTML parser and does not need to be; it is forgiving and never throws.

function firstMatch(re, html) {
  const m = re.exec(html);
  return m ? m[1] : null;
}

function metaContent(html, attr, value) {
  // <meta name="description" content="..."> / <meta property="og:title" content="...">
  // Matches regardless of attribute order (name|property first OR content first).
  const v = value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const a = attr.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const re1 = new RegExp(
    `<meta[^>]*\\b${a}\\s*=\\s*["']${v}["'][^>]*\\bcontent\\s*=\\s*["']([^"']*)["']`,
    'i',
  );
  const re2 = new RegExp(
    `<meta[^>]*\\bcontent\\s*=\\s*["']([^"']*)["'][^>]*\\b${a}\\s*=\\s*["']${v}["']`,
    'i',
  );
  return firstMatch(re1, html) ?? firstMatch(re2, html);
}

function countMatches(re, html) {
  const m = html.match(re);
  return m ? m.length : 0;
}

// Strip <head> contents we don't care about, return the <html ...> open tag attrs.
function htmlTagAttrs(html) {
  const m = /<html\b([^>]*)>/i.exec(html);
  return m ? m[1] : '';
}

// Approximate UTF-8 byte length (matches how probeUrl sizes the whole document).
function byteLen(s) {
  return Buffer.byteLength(String(s || ''), 'utf8');
}

// Coerce to a positive integer, else 0 (used for operator-tunable byte/time caps).
function positiveInt(v) {
  const n = Number(v);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : 0;
}

// Read a fetch Response body but NEVER buffer more than `maxBytes`. Prefers a bounded
// STREAM read (a real fetch exposes res.body.getReader) so an over-cap page is abandoned
// mid-stream and the bytes past the cap are never held in memory. Falls back to
// res.text() for simple stubs (tests) / runtimes without a stream body, post-checking the
// size. Returns { tooLarge:false, text } or { tooLarge:true, text:'' }; never throws on a
// normal body (a network error mid-stream is surfaced by the caller's try/catch).
async function readBodyCapped(res, maxBytes) {
  const stream = res && res.body;
  if (stream && typeof stream.getReader === 'function') {
    const reader = stream.getReader();
    const chunks = [];
    let received = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      if (value) {
        received += value.byteLength != null ? value.byteLength : value.length;
        if (received > maxBytes) {
          try { await reader.cancel(); } catch { /* best-effort */ }
          return { tooLarge: true, text: '' };
        }
        chunks.push(Buffer.from(value));
      }
    }
    return { tooLarge: false, text: Buffer.concat(chunks).toString('utf8') };
  }
  const text = await res.text();
  if (Buffer.byteLength(text, 'utf8') > maxBytes) return { tooLarge: true, text: '' };
  return { tooLarge: false, text };
}

// True if `tag` carries the named attribute, anchored so "data-width" / "data-src"
// do NOT match a request for "width" / "src".
function hasAttr(tag, name) {
  return new RegExp(`(?:^|\\s)${name}\\s*=`, 'i').test(tag);
}

// ---------------------------------------------------------------------------
// perfSignals(html) -> deterministic, BROWSER-FREE performance signals parsed
//   straight from the HTML (no Chromium, no layout, no network beyond the one
//   document fetch the probe already made):
//     * renderBlockingScripts  external <script src> WITHOUT async/defer/module
//     * stylesheets            <link rel="stylesheet"> (each blocks first paint)
//     * renderBlocking         the sum above — the headline "blocking resource" count
//     * imagesMissingDimensions <img> with no width+height (Cumulative-Layout-Shift risk)
//     * lazyImages             <img loading="lazy"> count (lazyImagesUsed = > 0)
//     * preconnect / preload   resource hints present? (resourceHints = either)
//     * inlineCssBytes/inlineJsBytes/inlineBytes  approx weight of inline <style>/<script>
//   Pure: same HTML => same signals. Forgiving regex (never throws), like the rest
//   of this module — it is a signal, not a spec-perfect HTML parser.
// ---------------------------------------------------------------------------
function perfSignals(h) {
  // Scripts: external (src) vs inline. Render-blocking = external AND not deferred
  // (no async, no defer, not type="module" — those don't block the parser).
  let scripts = 0;
  let renderBlockingScripts = 0;
  let inlineJsBytes = 0;
  const scriptRe = /<script\b([^>]*)>([\s\S]*?)<\/script>/gi;
  let sMatch;
  while ((sMatch = scriptRe.exec(h)) !== null) {
    const attrs = sMatch[1] || '';
    if (hasAttr(attrs, 'src')) {
      scripts += 1;
      const deferred = /(?:^|\s)(?:async|defer)\b/i.test(attrs)
        || /(?:^|\s)type\s*=\s*["']?module\b/i.test(attrs);
      if (!deferred) renderBlockingScripts += 1;
    } else {
      inlineJsBytes += byteLen(sMatch[2]);
    }
  }

  // Links: count render-blocking stylesheets + note preconnect/preload hints.
  let stylesheets = 0;
  let preconnect = false;
  let preload = false;
  const linkRe = /<link\b[^>]*>/gi;
  let lMatch;
  while ((lMatch = linkRe.exec(h)) !== null) {
    const rel = /(?:^|\s)rel\s*=\s*["']?([a-z -]+)/i.exec(lMatch[0]);
    const relVal = rel ? rel[1].toLowerCase() : '';
    if (/\bstylesheet\b/.test(relVal)) stylesheets += 1;
    if (/\bpreconnect\b/.test(relVal)) preconnect = true;
    if (/\bpreload\b/.test(relVal)) preload = true;
  }

  // Inline CSS weight from <style> blocks.
  let inlineCssBytes = 0;
  const styleRe = /<style\b[^>]*>([\s\S]*?)<\/style>/gi;
  let stMatch;
  while ((stMatch = styleRe.exec(h)) !== null) inlineCssBytes += byteLen(stMatch[1]);

  // Images: layout-shift risk (no intrinsic width+height) + lazy-loading usage.
  const imgTags = h.match(/<img\b[^>]*>/gi) || [];
  let imagesMissingDimensions = 0;
  let lazyImages = 0;
  for (const tag of imgTags) {
    if (!(hasAttr(tag, 'width') && hasAttr(tag, 'height'))) imagesMissingDimensions += 1;
    if (/(?:^|\s)loading\s*=\s*["']?lazy\b/i.test(tag)) lazyImages += 1;
  }

  return {
    scripts,
    renderBlockingScripts,
    stylesheets,
    renderBlocking: renderBlockingScripts + stylesheets,
    imagesMissingDimensions,
    lazyImages,
    lazyImagesUsed: lazyImages > 0,
    preconnect,
    preload,
    resourceHints: preconnect || preload,
    inlineCssBytes,
    inlineJsBytes,
    inlineBytes: inlineCssBytes + inlineJsBytes,
  };
}

// ---------------------------------------------------------------------------
// analyzeHtml(html, ctx) -> the deterministic on-page CHECKS object.
//   ctx = { url, status, https, responseMs, htmlBytes, robotsTxt, sitemapXml }
// Pure: same input => same output. No network, no clock, no randomness.
// ---------------------------------------------------------------------------
export function analyzeHtml(html, ctx = {}) {
  const h = String(html || '');

  const title = (firstMatch(/<title[^>]*>([\s\S]*?)<\/title>/i, h) || '').trim();
  const metaDesc = (metaContent(h, 'name', 'description') || '').trim();
  const canonical = metaContent(h, 'rel', 'canonical') !== null
    || /<link[^>]*\brel\s*=\s*["']canonical["']/i.test(h);
  const viewport = metaContent(h, 'name', 'viewport') !== null;

  const htmlAttrs = htmlTagAttrs(h);
  const lang = (firstMatch(/\blang\s*=\s*["']([^"']+)["']/i, htmlAttrs) || '').trim();
  const dir = (firstMatch(/\bdir\s*=\s*["']([^"']+)["']/i, htmlAttrs) || '').trim();

  const h1Count = countMatches(/<h1\b[^>]*>/gi, h);

  // Images + how many are missing a non-empty alt attribute.
  const imgTags = h.match(/<img\b[^>]*>/gi) || [];
  let imagesMissingAlt = 0;
  for (const tag of imgTags) {
    const alt = /\balt\s*=\s*["']([^"']*)["']/i.exec(tag);
    if (!alt || !alt[1].trim()) imagesMissingAlt += 1;
  }

  const og = {
    title: metaContent(h, 'property', 'og:title') !== null,
    description: metaContent(h, 'property', 'og:description') !== null,
    image: metaContent(h, 'property', 'og:image') !== null,
  };
  const twitterCard = metaContent(h, 'name', 'twitter:card') !== null;

  const structuredData = /<script[^>]*\btype\s*=\s*["']application\/ld\+json["']/i.test(h);

  return {
    https: Boolean(ctx.https),
    title: { present: title.length > 0, length: title.length },
    metaDescription: { present: metaDesc.length > 0, length: metaDesc.length },
    h1: { count: h1Count },
    viewport,
    lang: lang || null,
    dir: dir || null,
    canonical,
    openGraph: og,
    twitterCard,
    imagesTotal: imgTags.length,
    imagesMissingAlt,
    structuredData,
    // Browser-free performance signals parsed from the same HTML (render-blocking
    // resources, layout-shift risk, lazy-loading, resource hints, inline weight).
    performance: perfSignals(h),
    // robots.txt / sitemap.xml reachability are filled by probeUrl (separate fetches).
    robotsTxt: ctx.robotsTxt ?? null,
    sitemapXml: ctx.sitemapXml ?? null,
  };
}

// Build the canonical AUDIT object (the shape store/rules/report all consume).
// Pure given its inputs — used by both the probe and the lighthouse adapter.
export function buildAudit({ name, url, engine, timestamp, ok, status, metrics, checks }) {
  const audit = {
    schema: 1,
    name,
    url,
    engine,
    timestamp,
    ok: Boolean(ok),
    status: status ?? null,
    metrics: metrics || {},
    checks: checks || {},
  };
  audit.scores = scoreAudit(audit);
  // Roll the scores + findings up into one prospect verdict so EVERY audit carries
  // audit.verdict (the lighthouse adapter recomputes it after overriding scores).
  audit.verdict = computeVerdict(audit);
  return audit;
}

// ---------------------------------------------------------------------------
// probeUrl(name, url, deps) -> a full audit object. The ONLY impure function.
//   deps.fetchImpl   injectable fetch (defaults to global fetch) — tests pass a stub.
//   deps.now         injectable clock (defaults to Date.now) for the timestamp.
//   deps.timeoutMs   per-request TIME cap (default 15000) — aborts a slow fetch.
//   deps.maxBytes    per-response SIZE cap (default 5_000_000, or env SEO_PROBE_MAX_BYTES)
//                    — a hostile/huge page is abandoned rather than buffered (OOM guard).
//   deps.env         environment (default process.env) — drives the SSRF guard's
//                    PROSPECTS_PROBE_ALLOW_PRIVATE opt-in (see ssrf-guard.js).
//   deps.resolve     injectable DNS resolver for the SSRF guard (tests pass a stub
//                    so NO real DNS happens; defaults to a node:dns lookup).
//
// SSRF-safe: the operator-supplied URL is passed through assertUrlAllowed BEFORE the
// first fetch, and again on EVERY redirect target — we follow 3xx ourselves (bounded,
// redirect:'manual') so a public URL that 3xx-es to an internal host (the cloud
// metadata IP, a Docker service name, the LAN) is refused too. A blocked URL yields an
// ok:false audit with a "blocked by SSRF guard" status; on any network error it
// likewise returns an ok:false audit (the rules engine raises the finding). It NEVER
// throws — a scheduled run must always record SOMETHING.
// ---------------------------------------------------------------------------
export async function probeUrl(name, url, deps = {}) {
  const fetchImpl = deps.fetchImpl || globalThis.fetch;
  const nowIso = () => new Date(deps.now ? deps.now() : Date.now()).toISOString();
  const timeoutMs = deps.timeoutMs || 15000;
  // SIZE cap (the AbortController above bounds TIME; this bounds bytes). deps wins so
  // tests can drive a small cap; an operator can tune SEO_PROBE_MAX_BYTES via the env.
  const env = deps.env || (typeof process !== 'undefined' ? process.env : {});
  const maxBytes = positiveInt(deps.maxBytes) || positiveInt(env && env.SEO_PROBE_MAX_BYTES) || 5_000_000;
  const guardDeps = { env: deps.env, resolve: deps.resolve };
  const https = /^https:/i.test(url);
  const MAX_REDIRECTS = 5;

  if (typeof fetchImpl !== 'function') {
    throw new Error('probeUrl: no fetch implementation available (pass deps.fetchImpl).');
  }

  // A failed audit we can always fall back to — probeUrl itself never throws.
  const failed = (status, responseMs) => buildAudit({
    name,
    url,
    engine: 'probe',
    timestamp: nowIso(),
    ok: false,
    status,
    metrics: { responseMs: responseMs || 0, htmlBytes: 0, requests: 0 },
    checks: { https, robotsTxt: null, sitemapXml: null },
  });

  // Turn an SSRF-guard rejection into a clear (non-leaky) audit status string.
  const ssrfStatus = (err) => {
    const reason = String((err && err.message) || err || '').replace(/^SSRF guard:\s*/i, '').trim();
    return reason ? `blocked by SSRF guard: ${reason}` : 'blocked by SSRF guard';
  };

  // get(target): an SSRF-guarded fetch that follows redirects ITSELF (redirect:'manual')
  // so the guard re-checks every hop. Returns { ok, status, headers?, body, ms, blocked?,
  // error? } and never throws; blocked:true means the guard refused a hop.
  const get = async (target) => {
    const started = Date.now();
    let current = target;
    for (let hop = 0; ; hop += 1) {
      // Re-check BEFORE every fetch — the initial target AND each redirect target.
      try {
        await assertUrlAllowed(current, guardDeps);
      } catch (err) {
        return { ok: false, status: 0, body: '', ms: Date.now() - started, blocked: true, error: String((err && err.message) || err) };
      }

      const ac = typeof AbortController === 'function' ? new AbortController() : null;
      const t = ac ? setTimeout(() => ac.abort(), timeoutMs) : null;
      try {
        const res = await fetchImpl(current, {
          redirect: 'manual',
          headers: { 'user-agent': 'pi-system-seo-probe/1.0' },
          signal: ac ? ac.signal : undefined,
        });
        const location = res.status >= 300 && res.status < 400
          && res.headers && typeof res.headers.get === 'function'
          ? res.headers.get('location')
          : null;
        if (location) {
          if (hop >= MAX_REDIRECTS) {
            return { ok: false, status: 0, body: '', ms: Date.now() - started, error: 'too many redirects' };
          }
          try {
            current = new URL(location, current).toString();
          } catch {
            return { ok: false, status: 0, body: '', ms: Date.now() - started, error: 'invalid redirect location' };
          }
          continue; // loop re-runs the SSRF guard on the new target before fetching it
        }
        // SIZE GUARD: refuse an over-cap response. Check the DECLARED length first
        // (cheap), then bound the ACTUAL read in case the header is absent or lying.
        const declared = Number(
          res.headers && typeof res.headers.get === 'function' ? res.headers.get('content-length') : NaN,
        );
        if (Number.isFinite(declared) && declared > maxBytes) {
          return { ok: false, status: 0, body: '', ms: Date.now() - started, error: 'response too large' };
        }
        const read = await readBodyCapped(res, maxBytes);
        if (read.tooLarge) {
          return { ok: false, status: 0, body: '', ms: Date.now() - started, error: 'response too large' };
        }
        return { ok: true, status: res.status, headers: res.headers, body: read.text, ms: Date.now() - started };
      } catch (err) {
        return { ok: false, status: 0, body: '', ms: Date.now() - started, error: String((err && err.message) || err) };
      } finally {
        if (t) clearTimeout(t);
      }
    }
  };

  // --- SSRF gate on the operator-supplied URL, BEFORE the first fetch. -------
  try {
    await assertUrlAllowed(url, guardDeps);
  } catch (err) {
    return failed(ssrfStatus(err));
  }

  const page = await get(url);
  // A redirect hop pointed at an internal/blocked host — refuse the whole probe.
  if (page.blocked) {
    return failed(ssrfStatus(page.error), page.ms);
  }

  // Best-effort sibling fetches for robots.txt + sitemap.xml (never fatal; the SAME
  // guard applies to them and to any redirect they would follow).
  let robotsTxt = null;
  let sitemapXml = null;
  try {
    const base = new URL(url);
    const robots = await get(new URL('/robots.txt', base).toString());
    robotsTxt = robots.ok && robots.status >= 200 && robots.status < 400;
    const sm = await get(new URL('/sitemap.xml', base).toString());
    sitemapXml = sm.ok && sm.status >= 200 && sm.status < 400;
  } catch {
    // leave as null — a malformed URL just means we couldn't check these.
  }

  if (!page.ok || page.status >= 400) {
    // Unreachable / error response: record a failed audit (rules raise a finding).
    return buildAudit({
      name,
      url,
      engine: 'probe',
      timestamp: nowIso(),
      ok: false,
      status: page.status || null,
      metrics: { responseMs: page.ms, htmlBytes: 0, requests: 1 },
      checks: { https, robotsTxt, sitemapXml },
    });
  }

  const checks = analyzeHtml(page.body, {
    url,
    status: page.status,
    https,
    robotsTxt,
    sitemapXml,
  });
  // Response-header SECURITY checks (HTTPS/CSP/HSTS/cookies/…), normalised from the
  // page's own headers. Pure + header-set-agnostic (Fetch Headers, a Map, or a plain
  // object — see security.js headersToObject), so the audit carries trust/security
  // signals alongside the on-page SEO ones for scoring.js + rules.js.
  checks.security = analyzeSecurity(page.headers, { https });

  return buildAudit({
    name,
    url,
    engine: 'probe',
    timestamp: nowIso(),
    ok: true,
    status: page.status,
    metrics: {
      responseMs: page.ms,
      htmlBytes: Buffer.byteLength(page.body, 'utf8'),
      requests: 1,
      // Scalar roll-ups of the parsed perf signals, surfaced alongside the other
      // metrics for trend/report use (the full structured set lives in checks.performance).
      renderBlocking: checks.performance.renderBlocking,
      inlineBytes: checks.performance.inlineBytes,
    },
    checks,
  });
}
