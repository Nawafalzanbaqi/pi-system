// auth-sso — PROTECTED ROUTE SEGMENT. This layout guards everything under
// /account with a server-side session check (no middleware, so it composes with
// the i18n-bilingual middleware). Unauthenticated visitors are redirected to the
// login route and returned here afterwards.
import { requireSession } from '../../lib/auth/guard';

export const dynamic = 'force-dynamic';

export default async function AccountLayout({ children }) {
  await requireSession('/account');
  return children;
}
