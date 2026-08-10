// i18n-bilingual — localized home page.
//
// Loads the active locale's dictionary on the server and renders the language
// switcher. Replace this with your real content; the pattern (await params →
// getDictionary(locale) → render with logical-property CSS) is what matters.
import { getDictionary } from '../../i18n/dictionaries';
import { dir } from '../../i18n/config';
import LanguageSwitcher from '../../components/LanguageSwitcher';

// Rendered per request so the active locale — resolved from the middleware's
// x-pi-locale header in the root layout — is always honoured (correct lang/dir
// for both ar and en), matching the base's force-dynamic convention.
export const dynamic = 'force-dynamic';

export default async function LocaleHome({ params }) {
  const { locale } = await params;
  const t = await getDictionary(locale);

  return (
    <main className="i18n-page">
      <header className="i18n-bar">
        <h1>{t.appName}</h1>
        <LanguageSwitcher locale={locale} />
      </header>

      <p className="i18n-greeting">{t.greeting} 👋</p>
      <p>{t.tagline}</p>

      <ul>
        <li>{t.currentLanguage}: <code>{locale}</code></li>
        <li>{t.direction}: <code>{dir(locale)}</code></li>
        <li><a href={`/${locale}`}>{t.home}</a></li>
        <li><a href="/health">{t.healthCheck}</a> (<code>/health</code>)</li>
      </ul>
    </main>
  );
}
