export const metadata = {
  title: '__PROJECT_NAME__',
  description: 'Full-stack scaffold for pi-system (Next.js + .NET).',
};

// Base bilingual convention (pi-system): the default locale + text direction are
// stamped in at scaffold time from __DEFAULT_LOCALE__ (ar|en). Arabic is RTL, so
// `dir` is "rtl" for ar and "ltr" for en. This is the BASE plug-in point — the
// `i18n-bilingual` module REPLACES this layout with a per-request, locale-aware
// one (live switching + locale routes) when it is composed in.
export default function RootLayout({ children }) {
  return (
    <html lang="__DEFAULT_LOCALE__" dir="__DEFAULT_DIR__">
      <body>{children}</body>
    </html>
  );
}
