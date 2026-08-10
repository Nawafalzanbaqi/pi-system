// auth-sso — START the OIDC Authorization Code + PKCE login.
// Generates a PKCE verifier/challenge + state + nonce, stashes them in a sealed,
// short-lived transaction cookie, and redirects the browser to Keycloak's
// authorization endpoint. Lives under /api/auth/* (untouched by the i18n
// middleware). Node runtime — openid-client needs Node APIs.
import { NextResponse } from 'next/server';
import { generators } from 'openid-client';
import { getClient, oidcConfig, oidcConfigured } from '../../../../lib/auth/oidc';
import { seal, cookieOptions, TX_COOKIE, TX_MAX_AGE } from '../../../../lib/auth/session';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

function safeReturnTo(value) {
  // Same-app absolute paths only — never an open redirect.
  return typeof value === 'string' && value.startsWith('/') && !value.startsWith('//') ? value : '/';
}

export async function GET(request) {
  if (!oidcConfigured()) {
    return NextResponse.json(
      { error: 'OIDC is not configured (set OIDC_ISSUER_URL and the client credentials).' },
      { status: 503 },
    );
  }

  let client;
  try {
    client = await getClient();
  } catch (err) {
    return NextResponse.json({ error: 'OIDC discovery failed.', detail: String(err) }, { status: 502 });
  }

  const codeVerifier = generators.codeVerifier();
  const codeChallenge = generators.codeChallenge(codeVerifier);
  const state = generators.state();
  const nonce = generators.nonce();
  const returnTo = safeReturnTo(new URL(request.url).searchParams.get('returnTo'));

  const authorizationUrl = client.authorizationUrl({
    scope: oidcConfig.scope,
    code_challenge: codeChallenge,
    code_challenge_method: 'S256',
    state,
    nonce,
    redirect_uri: oidcConfig.redirectUri,
  });

  const res = NextResponse.redirect(authorizationUrl);
  res.cookies.set(
    TX_COOKIE,
    await seal({ codeVerifier, state, nonce, returnTo }, TX_MAX_AGE),
    cookieOptions(TX_MAX_AGE),
  );
  return res;
}
