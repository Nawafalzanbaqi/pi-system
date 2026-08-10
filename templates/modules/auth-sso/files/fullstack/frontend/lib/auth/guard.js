// auth-sso — server-side route guard. SERVER-SIDE ONLY.
// =============================================================================
// Protect a route SEGMENT by calling requireSession() in its layout (see
// app/account/layout.jsx). This deliberately uses a server-side check rather than
// Next.js middleware: the i18n-bilingual module already owns middleware.js (one
// per app), so a competing auth middleware would collide. A layout/page guard
// composes with i18n cleanly and is just as enforced (it runs on the server before
// anything renders).
// =============================================================================
import { redirect } from 'next/navigation';
import { getSession } from './session';

/** Require a logged-in user; otherwise redirect to the login route, remembering
 *  where to return to. Returns the session when present. */
export async function requireSession(returnTo) {
  const session = await getSession();
  if (!session) {
    const safe = typeof returnTo === 'string' && returnTo.startsWith('/') && !returnTo.startsWith('//')
      ? returnTo
      : '/';
    redirect(`/api/auth/login?returnTo=${encodeURIComponent(safe)}`);
  }
  return session;
}
