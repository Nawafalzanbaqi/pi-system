// bookings — booking page (locale-PREFIXED route, served at /<locale>/booking).
// =============================================================================
// The live route when the i18n-bilingual module is composed: its middleware
// redirects /booking -> /<locale>/booking, and (when present) its
// app/[locale]/layout.jsx validates the locale and wraps this page. Renders the
// SAME widget as the locale-agnostic /booking page, resolving the active locale
// from the route param. If i18n is NOT composed this route still works for an
// explicit /<ar|en>/booking URL, falling back to en for anything else.
// =============================================================================
import BookingWidget from '../../../components/BookingWidget';
import { getServices } from '../../../lib/bookings';
import { resolveLocale } from '../../../lib/bookings-i18n';

export const dynamic = 'force-dynamic';

export default async function LocaleBookingPage({ params }) {
  const { locale } = await params;
  const active = resolveLocale(locale, null);
  const services = await getServices();
  return (
    <main style={{ fontFamily: 'system-ui, sans-serif', padding: '2rem', lineHeight: 1.6 }}>
      <BookingWidget locale={active} services={services} />
    </main>
  );
}
