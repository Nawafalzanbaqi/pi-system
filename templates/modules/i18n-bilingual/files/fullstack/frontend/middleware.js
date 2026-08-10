// i18n-bilingual — locale routing middleware (App Router).
//
// 1. Un-prefixed paths ("/", "/about", ...) are redirected to the active locale
//    ("/<locale>/..."). The locale is chosen from the visitor's cookie, then the
//    Accept-Language header, then the scaffold default (__DEFAULT_LOCALE__).
// 2. Already-prefixed paths ("/ar/...", "/en/...") are passed through, with the
//    active locale forwarded to Server Components in the `x-pi-locale` request
//    header — so the root layout can set <html lang dir> on the server (correct
//    RTL/LTR, no client-side flash).
//
// Pure JavaScript — no external dependencies (ARM64-safe, no credentials).
import { NextResponse } from 'next/server';
import { locales, defaultLocale, isLocale, LOCALE_COOKIE } from './i18n/config';

// Paths that must never be localized or redirected (served as-is).
const SKIP = ['/health', '/api', '/_next', '/favicon.ico', '/robots.txt', '/sitemap.xml'];

function pickLocale(request) {
  const cookie = request.cookies.get(LOCALE_COOKIE)?.value;
  if (isLocale(cookie)) return cookie;

  const header = request.headers.get('accept-language') || '';
  for (const part of header.split(',')) {
    const tag = part.split(';')[0].trim().toLowerCase();
    const base = tag.split('-')[0];
    if (isLocale(base)) return base;
  }
  return defaultLocale;
}

export function middleware(request) {
  const { pathname } = request.nextUrl;

  if (SKIP.some((p) => pathname === p || pathname.startsWith(p + '/'))) {
    return NextResponse.next();
  }

  const maybeLocale = pathname.split('/')[1];

  if (isLocale(maybeLocale)) {
    // Already locale-prefixed: forward the active locale to Server Components.
    const headers = new Headers(request.headers);
    headers.set('x-pi-locale', maybeLocale);
    return NextResponse.next({ request: { headers } });
  }

  // No locale prefix: redirect to the chosen locale, preserving the rest of the path.
  const locale = pickLocale(request);
  const url = request.nextUrl.clone();
  url.pathname = `/${locale}${pathname === '/' ? '' : pathname}`;
  return NextResponse.redirect(url);
}

export const config = {
  // Skip Next internals and static assets; everything else flows through.
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
