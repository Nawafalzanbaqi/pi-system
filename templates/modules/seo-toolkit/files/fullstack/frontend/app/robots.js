// seo-toolkit — Next.js robots route (pi-system module).
//
// Next's app/robots.js convention serves /robots.txt automatically — a NEW file, so
// no collision. The i18n middleware already skips /robots.txt, so it is served
// as-is. It references the sitemap and keeps /api + the (auth-sso) /account area out
// of the index. force-dynamic so it reads the runtime SEO_SITE_URL from .env.
import { seoConfig } from '../lib/seo/config.js';
import { buildRobots } from '../lib/seo/robots-data.js';

export const dynamic = 'force-dynamic';

export default function robots() {
  return buildRobots(seoConfig());
}
