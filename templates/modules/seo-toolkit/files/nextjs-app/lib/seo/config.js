// seo-toolkit — central SEO config (pi-system module). No external dependencies.
//
// Resolves the site's SEO settings from the container environment (set by this
// module's compose fragment from .env). Read SERVER-SIDE only — these are not
// NEXT_PUBLIC_ vars, so values never reach client JS. Everything here is PURE
// (seoConfig takes an injectable `env`), so it is unit-testable without a server.
//
//   SEO_SITE_URL    the site's full public URL (absolute canonical/OG + sitemap)
//   SEO_SITE_NAME   the brand/site name (title fallback, OG, JSON-LD)
//   SEO_LOCALES     locales for sitemap/hreflang (default ar,en — matches i18n)
//
// COOPERATION WITH i18n-bilingual (without depending on it): the locale list comes
// from SEO_LOCALES (default ['ar','en'] — the i18n module's set), and the default
// locale from NEXT_PUBLIC_DEFAULT_LOCALE (which the base stamps into every Next.js
// service). When the site is localized (more than one locale) the sitemap/metadata
// emit per-locale, hreflang-tagged URLs; when it is single-locale they emit one
// un-prefixed set. The module never imports i18n's config, so it works with or
// without that module.

// A safe absolute fallback so the sitemap/robots/metadata always render even before
// SEO_SITE_URL is set. Set SEO_SITE_URL in .env for correct public URLs.
export const FALLBACK_BASE = 'http://localhost:3000';

export function seoConfig(env = process.env) {
  const siteUrl = String(env.SEO_SITE_URL || '').trim().replace(/\/+$/, '');
  const siteName = String(env.SEO_SITE_NAME || '').trim() || '__PROJECT_NAME__';
  const defaultLocale = String(env.NEXT_PUBLIC_DEFAULT_LOCALE || '').trim() || '__DEFAULT_LOCALE__';

  // Locale list: SEO_LOCALES wins; otherwise default to the i18n set (ar,en). The
  // default locale is always present and listed first.
  const raw = String(env.SEO_LOCALES || '').trim();
  let locales = raw ? raw.split(/[\s,]+/).filter(Boolean) : ['ar', 'en'];
  locales = [defaultLocale, ...locales.filter((l) => l && l !== defaultLocale)];

  return {
    siteUrl,
    base: siteUrl || FALLBACK_BASE,
    siteName,
    defaultLocale,
    locales,
    isLocalized: locales.length > 1,
    configured: siteUrl.length > 0,
  };
}

// Build an absolute URL for a path under a (possibly locale-prefixed) site.
export function absoluteUrl(config, path = '/', locale = null) {
  const tail = path === '/' ? '' : (path.startsWith('/') ? path : '/' + path);
  if (config.isLocalized && locale) return `${config.base}/${locale}${tail}`;
  return `${config.base}${tail}`;
}
