// seo-toolkit — bilingual sitemap data builder (pi-system module). Pure logic.
//
// buildSitemapEntries(config, paths, now) returns the array app/sitemap.js hands to
// Next. It is BILINGUAL-AWARE and cooperates with i18n-bilingual:
//   * localized site  -> one entry per locale ("/ar...", "/en...") AND an hreflang
//     `alternates.languages` map (each locale + an x-default) on every entry, which
//     is exactly how search engines learn the language variants of a page.
//   * single-locale   -> one un-prefixed entry per path.
// Pure (config + paths + an injectable clock) so it is unit-testable with no server.
import { absoluteUrl } from './config.js';

// The paths to include. A generated site reliably has "/"; add more here (or pass
// them in) as the site grows. Locale prefixes are added automatically when localized.
export const DEFAULT_PATHS = ['/'];

export function buildSitemapEntries(config, paths = DEFAULT_PATHS, now = new Date()) {
  const lastModified = now;
  const entries = [];

  for (const path of paths) {
    if (config.isLocalized) {
      // Shared hreflang map for all locale variants of this path.
      const languages = {};
      for (const loc of config.locales) languages[loc] = absoluteUrl(config, path, loc);
      languages['x-default'] = absoluteUrl(config, path, config.defaultLocale);

      for (const loc of config.locales) {
        entries.push({
          url: absoluteUrl(config, path, loc),
          lastModified,
          changeFrequency: 'weekly',
          priority: path === '/' ? 1 : 0.8,
          alternates: { languages },
        });
      }
    } else {
      entries.push({
        url: absoluteUrl(config, path),
        lastModified,
        changeFrequency: 'weekly',
        priority: path === '/' ? 1 : 0.8,
      });
    }
  }

  return entries;
}
