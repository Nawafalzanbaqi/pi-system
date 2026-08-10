// i18n-bilingual — root layout (replaces the base single-locale layout).
//
// The active locale is provided by the locale middleware via the `x-pi-locale`
// request header (derived from the URL's /<locale> prefix), so <html lang dir>
// is rendered correctly ON THE SERVER — RTL for Arabic, LTR for English — with no
// client-side flash. Falls back to the scaffold default locale for any request
// that reaches the layout without the header.
import './globals.css';
import { headers } from 'next/headers';
import { defaultLocale, dir, isLocale } from '../i18n/config';

export const metadata = {
  title: '__PROJECT_NAME__',
  description: 'Bilingual (Arabic/English) app scaffolded for pi-system.',
};

export default async function RootLayout({ children }) {
  const headerLocale = (await headers()).get('x-pi-locale');
  const locale = isLocale(headerLocale) ? headerLocale : defaultLocale;
  return (
    <html lang={locale} dir={dir(locale)}>
      <body>{children}</body>
    </html>
  );
}
