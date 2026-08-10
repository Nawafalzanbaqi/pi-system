// local-payments — payment return page (locale-PREFIXED, /<locale>/payment/return).
// =============================================================================
// The live return route when i18n-bilingual is composed. Renders the SAME status
// panel as the locale-agnostic /payment/return, resolving the locale from the route
// param. Works for an explicit /<ar|en>/payment/return URL even without i18n.
// =============================================================================
import PaymentStatus from '../../../../components/PaymentStatus';
import { resolveLocale } from '../../../../lib/payments-i18n';

export const dynamic = 'force-dynamic';

export default async function LocalePaymentReturnPage({ params, searchParams }) {
  const { locale } = await params;
  const sp = await searchParams;
  const active = resolveLocale(locale, null);
  const reference = typeof sp?.ref === 'string' ? sp.ref : '';
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <h2>{active === 'ar' ? 'حالة الدفع' : 'Payment status'}</h2>
      <PaymentStatus reference={reference} locale={active} />
    </main>
  );
}
