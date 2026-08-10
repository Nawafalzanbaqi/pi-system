// control-panel — LOG OUT. Clears the local session cookie and (RP-initiated
// logout) ends the Keycloak SSO session via the end-session endpoint with the
// id_token hint, then returns to the post-logout URL. Falls back to a local-only
// logout if the realm can't be reached. Node runtime.
import { NextResponse } from 'next/server';
import { getClient, oidcConfig, oidcConfigured } from '../../../../lib/auth/oidc.js';
import { getSession, SESSION_COOKIE } from '../../../../lib/auth/session.js';

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
      target = client.endSessionUrl({ id_token_hint: session?.id_token || undefined, post_logout_redirect_uri: postLogout });
    } catch { /* local-only logout */ }
  }

  const res = NextResponse.redirect(target);
  res.cookies.set(SESSION_COOKIE, '', { path: '/', maxAge: 0 });
  return res;
}
