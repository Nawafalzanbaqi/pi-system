// i18n-bilingual — central locale configuration (no external dependencies).
//
// This module ships Arabic + English. The DEFAULT locale comes from the base
// convention: the generator stamps NEXT_PUBLIC_DEFAULT_LOCALE into every Next.js
// service, and "__DEFAULT_LOCALE__" below is the scaffold-time fallback. Text
// direction is derived from the locale (Arabic is RTL), matching the base's
// __DEFAULT_DIR__ convention.
//
// To add a locale later: add its code to `locales`, drop a dictionary in
// locales/<code>.json, add a display name to `localeNames`, and (if it is
// right-to-left) list it in RTL_LOCALES. See the module README.

export const locales = ['ar', 'en'];

// Default locale: prefer the runtime/base-provided value, but only if it is one
// we actually support; otherwise fall back to the scaffold-time default.
const envDefault = process.env.NEXT_PUBLIC_DEFAULT_LOCALE;
export const defaultLocale = locales.includes(envDefault) ? envDefault : '__DEFAULT_LOCALE__';

// Cookie the language switcher sets so a visitor's choice survives navigation.
export const LOCALE_COOKIE = 'pi_locale';

// Right-to-left locales. Arabic is RTL; English is LTR.
const RTL_LOCALES = ['ar'];

export function dir(locale) {
  return RTL_LOCALES.includes(locale) ? 'rtl' : 'ltr';
}

export function isLocale(value) {
  return typeof value === 'string' && locales.includes(value);
}

// Human-readable names for the language switcher (each shown in its own script).
export const localeNames = {
  ar: 'العربية',
  en: 'English',
};
