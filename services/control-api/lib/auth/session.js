// control-panel — request-scoped session reads (uses next/headers). SERVER-ONLY.
// Thin wrapper over session-core for Route Handlers / Server Components. Writes
// are done on the NextResponse in the routes themselves (the reliable App Router
// pattern), using seal() + cookieOptions() from session-core.
import { cookies } from 'next/headers';
import { SESSION_COOKIE, TX_COOKIE, unseal } from './session-core.js';

/** The current user session, or null. */
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

export { SESSION_COOKIE, TX_COOKIE };
