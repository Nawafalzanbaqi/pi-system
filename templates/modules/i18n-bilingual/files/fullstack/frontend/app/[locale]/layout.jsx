// i18n-bilingual — locale segment layout.
//
// Validates the URL locale, exposes both locales to the static generator, and
// renders the localized subtree. The ROOT layout already provides <html>/<body>
// (with lang/dir from the middleware header); this layer scopes routing to a
// valid locale and is where you would add locale-wide providers later.
import { notFound } from 'next/navigation';
import { locales, isLocale } from '../../i18n/config';

export function generateStaticParams() {
  return locales.map((locale) => ({ locale }));
}

export default async function LocaleLayout({ children, params }) {
  const { locale } = await params;
  if (!isLocale(locale)) notFound();
  return children;
}
