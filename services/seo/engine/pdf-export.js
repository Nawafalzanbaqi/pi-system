// pi-system SEO engine — OPTIONAL Markdown -> PDF export (off by default, Pi-aware).
// ===========================================================================
// Turns a report's Markdown into a clean PDF — but ONLY if the operator has opted
// in to a renderer. The structure deliberately mirrors the OPTIONAL Lighthouse
// engine (services/seo/Dockerfile.lighthouse): the lightweight, dependency-free
// default path always works, and the heavy bit is opt-in, one-shot, never bundled.
//
//   ⚠ Honest Pi reasoning: a faithful HTML -> PDF renderer (headless Chromium,
//     wkhtmltopdf/Qt, WeasyPrint/Pango, …) is HEAVY and/or pulls native libraries.
//     Running one always-on — or even installing it by default — is exactly the
//     cost this platform avoids. So this module ships NO renderer. By default it
//     produces a clean, print-ready HTML (via the pure md-to-html.js core) and
//     KEEPS the Markdown; you get a PDF either by opening that HTML and "Save as
//     PDF" in any browser (zero Pi cost, perfect Arabic/RTL), or by opting in to a
//     pinned renderer (see services/seo/README.md → "Optional PDF export").
//
// The renderer is loaded LAZILY and only when SEO_PDF_RENDERER names an installed
// module, so its ABSENCE is never an error — it degrades to the HTML/Markdown. The
// renderer is also INJECTABLE (deps.renderPdf) so the whole path is unit-tested
// offline with a stub, with no real library and no network (tests/seo/run.sh).
// ===========================================================================

import { pathToFileURL } from 'node:url';
import { isAbsolute } from 'node:path';

import { renderHtmlDocument, detectDir } from './md-to-html.js';

// Resolve SEO_PDF_RENDERER to an import() specifier: a bare name is left as-is (it
// resolves from node_modules); a relative/absolute path or a file: URL is turned into
// a file URL so a local renderer SCRIPT works too (no package publish needed).
function toSpecifier(name) {
  if (/^[a-z]+:\/\//i.test(name)) return name; // already a URL (file:, etc.)
  if (name.startsWith('.') || name.startsWith('/') || name.startsWith('\\') || isAbsolute(name)) {
    try { return pathToFileURL(name).href; } catch { return name; }
  }
  return name; // bare module specifier
}

// Normalize whatever an optional renderer returns into a Buffer (or null).
function toBuffer(out) {
  if (!out) return null;
  if (Buffer.isBuffer(out)) return out;
  if (out instanceof Uint8Array) return Buffer.from(out);
  if (out.content && (Buffer.isBuffer(out.content) || out.content instanceof Uint8Array)) return Buffer.from(out.content);
  if (typeof out === 'string') return Buffer.from(out);
  return null;
}

// loadRenderer(env) -> async (html) => Buffer | null, or null when no renderer is
// configured/available. OFF by default: with SEO_PDF_RENDERER unset it returns null
// immediately (no import, no probe). When set to an installed module name OR a local
// renderer-script path it is dynamically imported; an absent or incompatible target
// degrades to null (never throws), so a missing renderer simply means "keep the
// Markdown + HTML".
export async function loadRenderer(env = {}) {
  const name = String(env.SEO_PDF_RENDERER || '').trim();
  if (!name) return null; // opt-in only
  try {
    const mod = await import(toSpecifier(name));
    const fn = mod.htmlToPdf || mod.toPdf || (typeof mod.default === 'function' ? mod.default : null);
    if (typeof fn !== 'function') return null;
    return async (html) => toBuffer(await fn(html, { format: 'A4', printBackground: true }));
  } catch {
    return null; // module not installed / not loadable -> graceful degrade
  }
}

// renderReportPdf(md, opts, deps) -> { html, pdf, degraded, reason }.
//   opts.title / opts.lang / opts.dir  passed through to the HTML document (pure).
//   deps.renderPdf                     an injected async (html)=>Buffer (tests/opt-in).
//   deps.env                           env carrying SEO_PDF_RENDERER (default process.env).
// The HTML is ALWAYS produced (the lightweight, always-available artifact). The PDF
// is produced only when a renderer is present and succeeds; otherwise degraded=true
// with a human reason explaining how to enable it — the Markdown is kept regardless.
export async function renderReportPdf(md, opts = {}, deps = {}) {
  const dir = opts.dir || detectDir(md);
  const html = renderHtmlDocument(md, { ...opts, dir });

  const renderPdf = deps.renderPdf || (await loadRenderer(deps.env || process.env));
  if (!renderPdf) {
    return {
      html,
      pdf: null,
      degraded: true,
      reason: 'no PDF renderer configured — set SEO_PDF_RENDERER to an installed renderer (see services/seo/README.md → "Optional PDF export"), or open the HTML and "Save as PDF". Keeping the Markdown + a print-ready HTML.',
    };
  }
  try {
    const pdf = await renderPdf(html);
    if (!pdf || !pdf.length) {
      return { html, pdf: null, degraded: true, reason: 'the configured PDF renderer produced no output — keeping the Markdown + HTML.' };
    }
    return { html, pdf, degraded: false, reason: '' };
  } catch (e) {
    return { html, pdf: null, degraded: true, reason: `the configured PDF renderer failed (${e && e.message ? e.message : e}) — keeping the Markdown + HTML.` };
  }
}
