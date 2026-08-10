// bookings — booking page (locale-AGNOSTIC route, served at /booking).
// =============================================================================
// Reachable at /booking when the i18n-bilingual module is NOT composed. When i18n
// IS composed, its middleware redirects /booking -> /<locale>/booking, served by
// app/[locale]/booking/page.jsx (which renders the SAME widget). Shipping both
// routes is what lets bookings cooperate with i18n without a broken reference in
// either mode. This page resolves the locale from the pi_locale cookie (which the
// i18n switcher sets) or the scaffold default, so it is bilingual on its own.
// =============================================================================
import { cookies } from 'next/headers';
import BookingWidget from '../../components/BookingWidget';
import { getServices } from '../../lib/bookings';
import { resolveLocale } from '../../lib/bookings-i18n';

// Rendered per request so services + the active locale are always live.
export const dynamic = 'force-dynamic';

export default async function BookingPage() {
  const cookieLocale = (await cookies()).get('pi_locale')?.value;
  const locale = resolveLocale(null, cookieLocale);
  const services = await getServices();
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <BookingWidget locale={locale} services={services} />
    </main>
  );
}
