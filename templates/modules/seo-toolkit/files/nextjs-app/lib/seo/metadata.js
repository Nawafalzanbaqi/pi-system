// seo-toolkit — page metadata builder (pi-system module). Pure logic.
//
// buildMetadata(config, opts) returns a Next.js Metadata object (title, description,
// canonical, hreflang alternates, Open Graph, Twitter card). Use it from a page's
// `generateMetadata` so each page gets correct, bilingual-aware tags WITHOUT this
// module having to replace any layout (cooperates with i18n / the base layout).
//
//   import { seoConfig } from '@/lib/seo/config';   // or a relative import
//   import { buildMetadata } from '@/lib/seo/metadata';
//   export async function generateMetadata({ params }) {
//     const { locale } = await params;               // from the [locale] segment
//     return buildMetadata(seoConfig(), { locale, path: '/', title: '...', description: '...' });
//   }
//
// Pure (config + opts in, plain object out) => unit-testable with no server.
import { absoluteUrl, FALLBACK_BASE } from './config.js';

export function buildMetadata(config, opts = {}) {
  const { locale, path = '/', title, description, images } = opts;
  const loc = locale || config.defaultLocale;
  const name = config.siteName;
  const finalTitle = title || name;
  const finalDesc = description || `${name} — ${loc === 'ar' ? 'موقع رسمي' : 'official site'}`;

  const canonical = config.isLocalized ? absoluteUrl(config, path, loc) : absoluteUrl(config, path);

  const languages = {};
  if (config.isLocalized) {
    for (const l of config.locales) languages[l] = absoluteUrl(config, path, l);
    languages['x-default'] = absoluteUrl(config, path, config.defaultLocale);
  }

  return {
    metadataBase: new URL(config.base || FALLBACK_BASE),
    title: finalTitle,
    description: finalDesc,
    alternates: {
      canonical,
      ...(config.isLocalized ? { languages } : {}),
    },
    openGraph: {
      title: finalTitle,
      description: finalDesc,
      url: canonical,
      siteName: name,
      locale: loc,
      type: 'website',
      ...(images ? { images } : {}),
    },
    twitter: {
      card: 'summary_large_image',
      title: finalTitle,
      description: finalDesc,
      ...(images ? { images } : {}),
    },
  };
}
