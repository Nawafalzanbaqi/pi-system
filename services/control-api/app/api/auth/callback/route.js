// control-panel — COMPLETE the OIDC login (Keycloak's redirect_uri target).
// Validates state, exchanges the code (with the PKCE verifier) for tokens,
// verifies the id_token (openid-client: signature via realm JWKS, nonce, aud,
// exp, iss), then seals an httpOnly session cookie holding the claims + the
// access token (server-side only) + a precomputed isOperator flag (so the UI can
// gate write affordances; the API still enforces the role on every write).
import { NextResponse } from 'next/server';
import { decodeJwt } from 'jose';
import { getClient, oidcConfig, oidcConfigured } from '../../../../lib/auth/oidc.js';
import { readTx, SESSION_COOKIE, TX_COOKIE } from '../../../../lib/auth/session.js';
import { seal, cookieOptions, SESSION_MAX_AGE } from '../../../../lib/auth/session-core.js';
import { hasOperatorRole } from '../../../../lib/auth-core.js';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

export async function GET(request) {
  const origin = oidcConfig.appBaseUrl || new URL(request.url).origin;
  if (!oidcConfigured()) return NextResponse.redirect(new URL('/?auth_error=unconfigured', origin));

  const tx = await readTx();
  if (!tx) return NextResponse.redirect(new URL('/?auth_error=expired', origin));

  let client;
  try { client = await getClient(); } catch { return NextResponse.redirect(new URL('/?auth_error=discovery', origin)); }

  const params = Object.fromEntries(new URL(request.url).searchParams.entries());
  let tokenSet;
  try {
    tokenSet = await client.callback(oidcConfig.redirectUri, params, {
      code_verifier: tx.codeVerifier, state: tx.state, nonce: tx.nonce,
    });
  } catch {
    const res = NextResponse.redirect(new URL('/?auth_error=exchange', origin));
    res.cookies.set(TX_COOKIE, '', { path: '/', maxAge: 0 });
    return res;
  }

  const claims = tokenSet.claims();
  // Precompute operator membership from the ACCESS token (the same token the API
  // verifies). We only persist a boolean — never expose roles/token to the browser.
  let isOperator = false;
  try {
    if (tokenSet.access_token) {
      const at = decodeJwt(tokenSet.access_token);
      isOperator = hasOperatorRole(at, {
        operatorRole: (process.env.CONTROL_API_OPERATOR_ROLE || 'operator').trim() || 'operator',
        audience: (process.env.CONTROL_API_OIDC_AUDIENCE || '').trim(),
      });
    }
  } catch { isOperator = false; }

  const session = {
    sub: claims.sub,
    name: claims.name || claims.preferred_username || null,
    email: claims.email || null,
    preferred_username: claims.preferred_username || null,
    isOperator,
    id_token: tokenSet.id_token || null,       // id_token_hint for RP-initiated logout
    access_token: tokenSet.access_token || null, // server-side ONLY; never sent to JS
  };

  const dest = typeof tx.returnTo === 'string' && tx.returnTo.startsWith('/') ? tx.returnTo : '/';
  const res = NextResponse.redirect(new URL(dest, origin));
  res.cookies.set(SESSION_COOKIE, await seal(session, SESSION_MAX_AGE), cookieOptions(SESSION_MAX_AGE));
  res.cookies.set(TX_COOKIE, '', { path: '/', maxAge: 0 });
  return res;
}
