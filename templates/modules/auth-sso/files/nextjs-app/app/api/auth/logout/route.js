// auth-sso — LOG OUT. Clears the local session cookie and (RP-initiated logout)
// redirects to Keycloak's end-session endpoint with the id_token hint, so the
// Keycloak SSO session is ended too — then back to the post-logout URL. If the
// realm can't be reached, it still clears the local session and lands on the
// post-logout URL. Lives under /api/auth/* (i18n-safe). Node runtime.
import { NextResponse } from 'next/server';
import { getClient, oidcConfig, oidcConfigured } from '../../../../lib/auth/oidc';
import { getSession, SESSION_COOKIE } from '../../../../lib/auth/session';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(request) {
  const origin = oidcConfig.appBaseUrl || new URL(request.url).origin;
  const postLogout = oidcConfig.postLogoutRedirectUri || `${origin}/`;
  const session = await getSession();

  let target = postLogout;
  if (oidcConfigured()) {
    try {
      const client = await getClient();
      target = client.endSessionUrl({
        id_token_hint: session?.id_token || undefined,
        post_logout_redirect_uri: postLogout,
      });
    } catch {
      // Fall back to a local-only logout.
    }
  }

  const res = NextResponse.redirect(target);
  res.cookies.set(SESSION_COOKIE, '', { path: '/', maxAge: 0 });
  return res;
}
