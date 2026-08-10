// ===========================================================================
// pi-system Control API — JWT VERIFICATION SEAM (jose / Keycloak JWKS)
// ---------------------------------------------------------------------------
// The ONLY place a token's SIGNATURE is checked. It fetches Keycloak's JWKS
// (cached + auto-rotated by jose) and verifies the token against the configured
// issuer + audience, then hands the VERIFIED payload to the pure decision logic
// in auth-core.js. Isolated here so tests never need jose or the network.
//
// A token that fails ANY check (signature, issuer, audience, expiry) throws, and
// the caller treats that as 401 — fail closed.
// ===========================================================================
import { createRemoteJWKSet, jwtVerify } from 'jose';

import { isAuthConfigured } from './config.js';

const _jwksCache = new Map();

function jwksFor(config) {
  let jwks = _jwksCache.get(config.jwksUri);
  if (!jwks) {
    jwks = createRemoteJWKSet(new URL(config.jwksUri));
    _jwksCache.set(config.jwksUri, jwks);
  }
  return jwks;
}

// Verify a raw token string -> the decoded payload (throws on any failure).
export async function verifyToken(token, config) {
  if (!isAuthConfigured(config)) {
    // Refuse to run unauthenticated: misconfiguration must NOT silently allow access.
    throw new Error('OIDC is not configured (CONTROL_API_OIDC_* missing)');
  }
  const { payload } = await jwtVerify(token, jwksFor(config), {
    issuer: config.issuer,
    audience: config.audience,
  });
  return payload;
}
