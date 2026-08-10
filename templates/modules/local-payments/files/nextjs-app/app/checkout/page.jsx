// local-payments — checkout page (locale-AGNOSTIC route, served at /checkout).
// =============================================================================
// Reachable at /checkout when the i18n-bilingual module is NOT composed. When i18n
// IS composed, its middleware redirects /checkout -> /<locale>/checkout, served by
// app/[locale]/checkout/page.jsx (same widget). Shipping both routes lets
// local-payments cooperate with i18n without a broken reference in either mode.
// =============================================================================
import { cookies } from 'next/headers';
import CheckoutWidget from '../../components/CheckoutWidget';
import { resolveLocale } from '../../lib/payments-i18n';

export const dynamic = 'force-dynamic';

export default async function CheckoutPage() {
  const cookieLocale = (await cookies()).get('pi_locale')?.value;
  const locale = resolveLocale(null, cookieLocale);
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <CheckoutWidget locale={locale} returnPath="/payment/return" />
    </main>
  );
}
