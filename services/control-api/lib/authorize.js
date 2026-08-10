// ===========================================================================
// pi-system Control API — request AUTHORIZATION (seam wiring)
// ---------------------------------------------------------------------------
// Combines the verification SEAM (verify-token.js) with the pure decision logic
// (auth-core.js) into the one helper every protected route calls:
//
//   const auth = await authorize(request, { requireOperator });
//   if (auth.response) return auth.response;   // 401 / 403 already built
//   // ... use auth.payload / auth.identity ...
//
// Order of checks (fail closed at each step):
//   1. no/!malformed Authorization header  -> 401
//   2. signature/issuer/audience/expiry bad -> 401
//   3. write/action without operator role   -> 403
//
// PART #2 — the browser panel authenticates with an httpOnly session cookie (BFF,
// see lib/auth/*). When there is no Authorization header we additionally accept
// the SAME Keycloak access token sealed inside that cookie and verify it through
// the IDENTICAL path (jose JWKS signature + issuer + audience + operator role).
// This is an extra transport, NOT a weaker check; the bearer-header path (used by
// programmatic clients and every existing test) is unchanged.
// ===========================================================================
import { extractBearer, evaluateAuth, identityOf } from './auth-core.js';
import { verifyToken } from './verify-token.js';
import { getConfig } from './config.js';
import { unauthorized, forbidden, serverError } from './http.js';
import { SESSION_COOKIE, readCookie, unseal } from './auth/session-core.js';

// Resolve the bearer token from the Authorization header first, then (browser UI)
// from the encrypted session cookie. Returns the raw token string or null.
async function resolveToken(request) {
  const header = extractBearer(request.headers.get('authorization'));
  if (header) return header;
  const raw = readCookie(request.headers.get('cookie') || '', SESSION_COOKIE);
  if (!raw) return null;
  try {
    const session = await unseal(raw);
    return session && typeof session.access_token === 'string' ? session.access_token : null;
  } catch {
    return null;
  }
}

export async function authorize(request, { requireOperator = false, config = getConfig() } = {}) {
  const token = await resolveToken(request);
  if (!token) return { response: unauthorized('missing or malformed bearer token') };

  let payload;
  try {
    payload = await verifyToken(token, config);
  } catch (e) {
    // Distinguish "we can't verify because we're misconfigured" (500) from a
    // genuinely bad token (401) — but never leak details either way.
    if (e && /not configured/i.test(String(e.message))) {
      return { response: serverError('authentication is not configured on the server') };
    }
    return { response: unauthorized('invalid token') };
  }

  const decision = evaluateAuth({ payload, config, requireOperator });
  if (!decision.ok) {
    return { response: decision.status === 403 ? forbidden(decision.error) : unauthorized(decision.error) };
  }
  return { payload, identity: identityOf(payload), config };
}
