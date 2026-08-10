// seo-toolkit — Next.js sitemap route (pi-system module).
//
// Next's app/sitemap.js convention serves /sitemap.xml automatically — a NEW file,
// so it never collides with the base/i18n/auth layouts. The i18n middleware already
// skips /sitemap.xml, so it is served as-is (not redirected to a locale). The
// bilingual entries (per-locale URLs + hreflang) come from the pure builder.
//
// force-dynamic so the sitemap is built at REQUEST time and reads the RUNTIME
// container env (SEO_SITE_URL etc., set from .env) rather than baking in build-time
// values — the same lesson the web-analytics module applies.
import { seoConfig } from '../lib/seo/config.js';
import { buildSitemapEntries, DEFAULT_PATHS } from '../lib/seo/sitemap-data.js';

export const dynamic = 'force-dynamic';

export default function sitemap() {
  return buildSitemapEntries(seoConfig(), DEFAULT_PATHS);
}
