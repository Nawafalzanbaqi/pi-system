// seo-toolkit — JSON-LD structured-data scaffolding (pi-system module). Pure logic.
//
// Schema.org structured data helps search engines understand the site and can earn
// rich results. These builders produce the Organization + WebSite scaffolding most
// sites want; extend them (LocalBusiness, Product, BreadcrumbList, ...) per site.
// Pure (config in, plain JSON-LD objects out) => unit-testable; rendered by
// components/StructuredData.jsx.
import { FALLBACK_BASE } from './config.js';

export function organizationLd(config) {
  const base = config.base || FALLBACK_BASE;
  return {
    '@context': 'https://schema.org',
    '@type': 'Organization',
    name: config.siteName,
    url: base,
  };
}

export function websiteLd(config) {
  const base = config.base || FALLBACK_BASE;
  return {
    '@context': 'https://schema.org',
    '@type': 'WebSite',
    name: config.siteName,
    url: base,
    inLanguage: config.locales,
  };
}

// All the site-wide JSON-LD blocks, ready to render.
export function allLd(config) {
  return [organizationLd(config), websiteLd(config)];
}
