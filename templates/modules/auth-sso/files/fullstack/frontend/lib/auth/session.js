// auth-sso — encrypted session + login-transaction cookies. SERVER-SIDE ONLY.
// =============================================================================
// The session holds the user's claims + tokens. It is sealed as a JWE
// (AES-256-GCM, "dir") with a key derived from APP_SECRET, so the browser can
// neither read nor tamper with it. Uses `jose` (pure JS -> ARM64-safe), pinned.
//
// READ helpers (getSession / readTx) are safe in Server Components AND Route
// Handlers. WRITES are intentionally NOT done here: a Route Handler that returns a
// redirect must set cookies on its NextResponse, so the routes call `seal()` +
// `cookieOptions()` and set the cookie on the response themselves (the reliable
// pattern in the App Router).
// =============================================================================
import { createHash } from 'node:crypto';
import { EncryptJWT, jwtDecrypt } from 'jose';
import { cookies } from 'next/headers';

export const SESSION_COOKIE = 'pi_session';
export const TX_COOKIE = 'pi_auth_tx'; // short-lived: PKCE verifier + state + nonce
export const SESSION_MAX_AGE = Number(process.env.OIDC_SESSION_MAX_AGE || 28800); // 8h
export const TX_MAX_AGE = 600; // 10 min to complete the login round-trip

function key() {
  const secret = (process.env.OIDC_SESSION_SECRET || process.env.APP_SECRET || '').trim();
  if (!secret) {
    throw new Error('Set APP_SECRET (or OIDC_SESSION_SECRET) to encrypt the session cookie.');
  }
  return createHash('sha256').update(secret).digest(); // 32 bytes for A256GCM
}

/** Seal a payload into a compact JWE string with an absolute expiry. */
export async function seal(payload, maxAgeSec) {
  const now = Math.floor(Date.now() / 1000);
  return new EncryptJWT(payload)
    .setProtectedHeader({ alg: 'dir', enc: 'A256GCM' })
    .setIssuedAt(now)
    .setExpirationTime(now + maxAgeSec)
    .encrypt(key());
}

/** Decrypt + validate (exp) a sealed cookie; null if missing, expired or tampered. */
export async function unseal(token) {
  try {
    const { payload } = await jwtDecrypt(token, key());
    return payload;
  } catch {
    return null;
  }
}

/** Cookie attributes: httpOnly + Secure (Caddy terminates TLS) + SameSite=Lax so
 *  the cookie survives the OIDC redirect back from Keycloak. */
export function cookieOptions(maxAge) {
  return { httpOnly: true, secure: true, sameSite: 'lax', path: '/', maxAge };
}

/** The current user session, or null. Safe in Server Components and Route Handlers. */
export async function getSession() {
  const store = await cookies();
  const token = store.get(SESSION_COOKIE)?.value;
  return token ? unseal(token) : null;
}

/** The pending login transaction (PKCE verifier/state/nonce), or null. */
export async function readTx() {
  const store = await cookies();
  const token = store.get(TX_COOKIE)?.value;
  return token ? unseal(token) : null;
}
