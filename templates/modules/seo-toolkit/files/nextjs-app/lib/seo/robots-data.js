// seo-toolkit — robots.txt data builder (pi-system module). Pure logic.
//
// buildRobots(config) returns the object app/robots.js hands to Next. It allows
// crawling of the public site, keeps API routes and the (auth-sso) /account area
// out of the index, and points crawlers at the sitemap — so robots.txt and
// sitemap.xml are consistent. Pure (config in, object out) => unit-testable.
import { FALLBACK_BASE } from './config.js';

export function buildRobots(config) {
  const base = config.base || FALLBACK_BASE;
  return {
    rules: [
      {
        userAgent: '*',
        allow: '/',
        // Don't index API routes or the private account area (cooperates with
        // auth-sso, whose protected segment lives at /account and /<locale>/account).
        disallow: ['/api/', '/account', '/account/'],
      },
    ],
    sitemap: `${base}/sitemap.xml`,
    host: base,
  };
}
