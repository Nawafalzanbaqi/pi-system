// Root layout for the control panel UI. SERVER component.
// ---------------------------------------------------------------------------
// Sets <html lang/dir/data-theme> from the operator's saved cookies so the very
// first paint is already in the right language, direction and theme (no flash),
// then the client shell keeps them in sync. Fonts are self-hosted by next/font
// (downloaded at build time, served from our origin) — NO runtime CDN, which
// keeps the panel usable on an offline/air-gapped Pi and leaks nothing.
import './globals.css';
import { cookies } from 'next/headers';
import { Inter, IBM_Plex_Sans_Arabic, JetBrains_Mono } from 'next/font/google';

const inter = Inter({ subsets: ['latin'], variable: '--font-en', display: 'swap' });
const plexAr = IBM_Plex_Sans_Arabic({
  subsets: ['arabic', 'latin'],
  weight: ['300', '400', '500', '600', '700'],
  variable: '--font-ar',
  display: 'swap',
});
const mono = JetBrains_Mono({ subsets: ['latin'], variable: '--font-mono', display: 'swap' });

export const metadata = {
  title: 'π · control panel',
  description: 'pi-system — self-hosted platform control panel',
  robots: { index: false, follow: false },
};

export default async function RootLayout({ children }) {
  const store = await cookies();
  const theme = store.get('pi_theme')?.value === 'dark' ? 'dark' : 'light';
  const lang = store.get('pi_lang')?.value === 'en' ? 'en' : 'ar';
  const dir = lang === 'ar' ? 'rtl' : 'ltr';

  return (
    <html lang={lang} dir={dir} data-theme={theme}
      className={`${inter.variable} ${plexAr.variable} ${mono.variable}`}>
      <body>
        <div id="__pi_root">{children}</div>
      </body>
    </html>
  );
}
