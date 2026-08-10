// control-panel — session sealing CORE (PURE: jose only, NO next/headers).
// ===========================================================================
// The session holds the user's claims + the Keycloak access token. It is sealed
// as a JWE (AES-256-GCM, "dir") with a key derived from CONTROL_API_SESSION_SECRET
// so the BROWSER can neither read nor tamper with it (the access token never
// reaches client JavaScript — the strongest place to keep it). Pure on purpose:
// lib/authorize.js imports `unseal` to resolve the cookie's token without pulling
// in next/headers, and tests can exercise sealing without a request context.
import { createHash } from 'node:crypto';
import { EncryptJWT, jwtDecrypt } from 'jose';

export const SESSION_COOKIE = 'pi_panel_session';
export const TX_COOKIE = 'pi_panel_tx'; // short-lived: PKCE verifier + state + nonce
export const SESSION_MAX_AGE = Number(process.env.CONTROL_API_OIDC_SESSION_MAX_AGE || 28800); // 8h
export const TX_MAX_AGE = 600; // 10 min to complete the login round-trip

export function sessionSecretConfigured() {
  return Boolean((process.env.CONTROL_API_SESSION_SECRET || '').trim());
}

function key() {
  const secret = (process.env.CONTROL_API_SESSION_SECRET || '').trim();
  if (!secret) throw new Error('Set CONTROL_API_SESSION_SECRET to encrypt the panel session cookie.');
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

/** Decrypt + validate (exp) a sealed cookie; null if missing/expired/tampered. */
export async function unseal(token) {
  try {
    if (!token) return null;
    const { payload } = await jwtDecrypt(token, key());
    return payload;
  } catch {
    return null;
  }
}

/** Cookie attributes: httpOnly + Secure (Caddy terminates TLS) + SameSite=Lax so
 *  the cookie survives the OIDC redirect back from Keycloak AND is NOT sent on
 *  cross-site POSTs (CSRF-safe for the state-changing action endpoints). */
export function cookieOptions(maxAge) {
  return { httpOnly: true, secure: true, sameSite: 'lax', path: '/', maxAge };
}

/** Read one cookie value out of a raw `Cookie:` header (no next/headers needed). */
export function readCookie(cookieHeader, name) {
  if (typeof cookieHeader !== 'string' || !cookieHeader) return null;
  for (const part of cookieHeader.split(';')) {
    const eq = part.indexOf('=');
    if (eq < 0) continue;
    if (part.slice(0, eq).trim() === name) return part.slice(eq + 1).trim();
  }
  return null;
}
