// local-payments — payment return page (locale-AGNOSTIC, served at /payment/return).
// =============================================================================
// Where the provider (or the mock flow) sends the payer back to, with ?ref=<ref>.
// Reachable at /payment/return when i18n is NOT composed; with i18n the middleware
// redirects to /<locale>/payment/return (same panel). The backend's callback_url is
// built as /payment/return?ref=..., so both routes exist to avoid a broken ref.
// =============================================================================
import { cookies } from 'next/headers';
import PaymentStatus from '../../../components/PaymentStatus';
import { resolveLocale } from '../../../lib/payments-i18n';

export const dynamic = 'force-dynamic';

export default async function PaymentReturnPage({ searchParams }) {
  const sp = await searchParams;
  const reference = typeof sp?.ref === 'string' ? sp.ref : '';
  const cookieLocale = (await cookies()).get('pi_locale')?.value;
  const locale = resolveLocale(null, cookieLocale);
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <h2>{locale === 'ar' ? 'حالة الدفع' : 'Payment status'}</h2>
      <PaymentStatus reference={reference} locale={locale} />
    </main>
  );
}
