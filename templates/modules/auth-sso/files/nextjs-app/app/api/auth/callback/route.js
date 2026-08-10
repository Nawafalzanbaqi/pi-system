// auth-sso — COMPLETE the OIDC login (the redirect_uri Keycloak sends the user to).
// Validates state, exchanges the authorization code (with the PKCE verifier) for
// tokens, verifies the id_token (signature via the realm JWKS, nonce, aud, exp,
// iss — all done by openid-client), then seals a session cookie and returns the
// user to where they started. Lives under /api/auth/* (i18n-safe). Node runtime.
import { NextResponse } from 'next/server';
import { getClient, oidcConfig, oidcConfigured } from '../../../../lib/auth/oidc';
import {
  readTx,
  seal,
  cookieOptions,
  SESSION_COOKIE,
  TX_COOKIE,
  SESSION_MAX_AGE,
} from '../../../../lib/auth/session';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(request) {
  const origin = oidcConfig.appBaseUrl || new URL(request.url).origin;

  if (!oidcConfigured()) {
    return NextResponse.json({ error: 'OIDC is not configured.' }, { status: 503 });
  }

  const tx = await readTx();
  if (!tx) {
    // No/expired transaction cookie -> the login took too long or was replayed.
    return NextResponse.redirect(new URL('/?auth_error=expired', origin));
  }

  let client;
  try {
    client = await getClient();
  } catch {
    return NextResponse.redirect(new URL('/?auth_error=discovery', origin));
  }

  const params = Object.fromEntries(new URL(request.url).searchParams.entries());

  let tokenSet;
  try {
    tokenSet = await client.callback(oidcConfig.redirectUri, params, {
      code_verifier: tx.codeVerifier,
      state: tx.state,
      nonce: tx.nonce,
    });
  } catch {
    const res = NextResponse.redirect(new URL('/?auth_error=exchange', origin));
    res.cookies.set(TX_COOKIE, '', { path: '/', maxAge: 0 });
    return res;
  }

  const claims = tokenSet.claims();
  const session = {
    sub: claims.sub,
    name: claims.name || claims.preferred_username || null,
    email: claims.email || null,
    preferred_username: claims.preferred_username || null,
    id_token: tokenSet.id_token || null, // id_token_hint for RP-initiated logout
    access_token: tokenSet.access_token || null, // forwarded to the backend
  };

  const dest = typeof tx.returnTo === 'string' && tx.returnTo.startsWith('/') ? tx.returnTo : '/';
  const res = NextResponse.redirect(new URL(dest, origin));
  res.cookies.set(SESSION_COOKIE, await seal(session, SESSION_MAX_AGE), cookieOptions(SESSION_MAX_AGE));
  res.cookies.set(TX_COOKIE, '', { path: '/', maxAge: 0 }); // consume the transaction
  return res;
}
