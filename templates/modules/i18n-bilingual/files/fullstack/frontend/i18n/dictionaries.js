// i18n-bilingual — server-side dictionary loader.
//
// Message catalogues are plain JSON in locales/<code>.json and loaded on demand
// via dynamic import, so Next.js's output file tracing bundles only what is used
// into the standalone build. Call getDictionary(locale) from Server Components.

const dictionaries = {
  ar: () => import('../locales/ar.json').then((m) => m.default),
  en: () => import('../locales/en.json').then((m) => m.default),
};

export async function getDictionary(locale) {
  const load = dictionaries[locale] || dictionaries['__DEFAULT_LOCALE__'] || dictionaries.ar;
  return load();
}
