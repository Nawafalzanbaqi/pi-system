// auth-sso — i18n-cooperating variant of the protected segment. When the
// i18n-bilingual module is composed in, the middleware rewrites /account to
// /<locale>/account; this guard protects that path and returns the visitor to the
// locale-prefixed page after login. When i18n is absent this route is dormant
// (the un-prefixed /account guard above is used instead) — mirrors how the
// bookings module ships both /booking and /<locale>/booking.
import { requireSession } from '../../../lib/auth/guard';

export const dynamic = 'force-dynamic';

export default async function LocaleAccountLayout({ children, params }) {
  const { locale } = await params;
  await requireSession(`/${locale}/account`);
  return children;
}
