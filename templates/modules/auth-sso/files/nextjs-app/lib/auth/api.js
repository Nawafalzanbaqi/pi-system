// auth-sso — call a protected backend with the user's access token. SERVER-SIDE.
// =============================================================================
// Demonstrates the END-TO-END loop: the frontend holds the session, and forwards
// the user's access token as a Bearer header to the .NET backend, which validates
// it (see Auth/OidcHostingStartup.cs). The backend is internal-only, so this runs
// server-side (Server Components / Route Handlers) — the token never reaches the
// browser.
//
// Backend URL resolution: BACKEND_URL (set by the fullstack base ->
// http://<name>-api:8080), else BOOKINGS_API_URL. A plain nextjs-app with no
// backend wired leaves both blank -> backendConfigured() is false and the UI says
// so instead of failing.
// =============================================================================
import { getSession } from './session';

const BACKEND = (process.env.BACKEND_URL || process.env.BOOKINGS_API_URL || '').replace(/\/+$/, '');

export function backendConfigured() {
  return BACKEND.length > 0;
}

/** GET a backend path, attaching the session's access token when present.
 *  Returns { ok, status, data } and never throws into the request. */
export async function callBackend(path) {
  if (!BACKEND) return { ok: false, status: 0, data: null, reason: 'no-backend' };
  const session = await getSession();
  const headers = { Accept: 'application/json' };
  if (session?.access_token) headers.Authorization = `Bearer ${session.access_token}`;
  try {
    const res = await fetch(`${BACKEND}${path}`, { headers, cache: 'no-store' });
    let data = null;
    try { data = await res.json(); } catch { /* empty / non-JSON body */ }
    return { ok: res.ok, status: res.status, data };
  } catch (err) {
    return { ok: false, status: 502, data: null, reason: String(err) };
  }
}
