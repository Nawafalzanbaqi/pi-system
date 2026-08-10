// auth-sso — tiny server component showing the current auth state with sign-in /
// sign-out links. Server-rendered (no client JS): it reads the encrypted session
// cookie on the server. The links are plain GETs to /api/auth/* (routes the i18n
// middleware leaves untouched). Drop <AuthStatus /> into any layout or page to
// surface login — it is intentionally NOT injected into the base home page so it
// never collides with the i18n-bilingual page/layout replacement.
import { getSession } from '../lib/auth/session';

export default async function AuthStatus() {
  const session = await getSession();
  const wrap = { display: 'inline-flex', gap: '0.5rem', alignItems: 'center' };

  if (!session) {
    return (
      <span style={wrap}>
        <a href="/api/auth/login">Sign in</a>
      </span>
    );
  }

  return (
    <span style={wrap}>
      <span>Signed in as <strong>{session.name || session.preferred_username || session.sub}</strong></span>
      <span aria-hidden="true">·</span>
      <a href="/api/auth/logout">Sign out</a>
    </span>
  );
}
