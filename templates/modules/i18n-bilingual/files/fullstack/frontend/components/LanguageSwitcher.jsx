'use client';

// i18n-bilingual — language switcher.
//
// Swaps the leading /<locale> segment of the current path and remembers the
// choice in a cookie so it survives navigation and return visits. Renders one
// button per supported locale, each labelled in its own script.
import { usePathname, useRouter } from 'next/navigation';
import { locales, localeNames, isLocale, LOCALE_COOKIE } from '../i18n/config';

export default function LanguageSwitcher({ locale }) {
  const pathname = usePathname();
  const router = useRouter();

  function switchTo(target) {
    if (target === locale) return;
    // Persist the choice for a year (the middleware reads this cookie).
    document.cookie = `${LOCALE_COOKIE}=${target}; path=/; max-age=31536000; samesite=lax`;

    const segments = (pathname || '/').split('/');
    if (isLocale(segments[1])) segments[1] = target;
    else segments.splice(1, 0, target);

    router.push(segments.join('/') || `/${target}`);
    router.refresh();
  }

  return (
    <nav aria-label="Language" style={{ display: 'flex', gap: '0.5rem' }}>
      {locales.map((l) => (
        <button
          key={l}
          type="button"
          lang={l}
          onClick={() => switchTo(l)}
          aria-current={l === locale ? 'true' : undefined}
          style={{
            padding: '0.25rem 0.75rem',
            cursor: 'pointer',
            borderRadius: '0.375rem',
            border: '1px solid currentColor',
            background: l === locale ? 'currentColor' : 'transparent',
            color: l === locale ? 'Canvas' : 'inherit',
            fontWeight: l === locale ? 700 : 400,
          }}
        >
          {localeNames[l] || l}
        </button>
      ))}
    </nav>
  );
}
