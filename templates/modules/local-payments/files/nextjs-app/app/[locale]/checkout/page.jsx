// local-payments — checkout page (locale-PREFIXED route, served at /<locale>/checkout).
// =============================================================================
// The live route when the i18n-bilingual module is composed (its middleware
// redirects /checkout -> /<locale>/checkout and its [locale]/layout wraps this).
// Renders the SAME widget as the locale-agnostic /checkout page, resolving the
// active locale from the route param. Works for an explicit /<ar|en>/checkout URL
// even without i18n.
// =============================================================================
import CheckoutWidget from '../../../components/CheckoutWidget';
import { resolveLocale } from '../../../lib/payments-i18n';

export const dynamic = 'force-dynamic';

export default async function LocaleCheckoutPage({ params }) {
  const { locale } = await params;
  const active = resolveLocale(locale, null);
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <CheckoutWidget locale={active} returnPath={`/${active}/payment/return`} />
    </main>
  );
}
