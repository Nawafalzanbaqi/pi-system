// bookings — SERVER-SIDE client for the booking API on the .NET backend.
// =============================================================================
// SERVER-SIDE ONLY. The booking API runs on the .NET backend, which is on the
// internal Docker network with NO public port — the browser can never reach it
// directly. These helpers run on the Next.js server (Server Components and the
// Route Handlers under app/api/bookings/) and proxy to the backend, keeping the
// booking write server-side.
//
// No external dependencies — built-in fetch only (Node 18+ / Next 15).
//
// Base URL resolution (first non-empty wins):
//   1. BOOKINGS_API_URL  explicit override — set this for a nextjs-app base that
//                        pairs with a SEPARATE bookings backend (and pass it into
//                        the web container; see the module README).
//   2. BACKEND_URL       set by the fullstack base -> http://<name>-api:8080.
// With neither set (a plain nextjs-app with no backend wired yet) the helpers
// return empty / a clear 503 instead of throwing, so the UI degrades gracefully.
// =============================================================================

const API_BASE = (process.env.BOOKINGS_API_URL || process.env.BACKEND_URL || '').replace(/\/+$/, '');

/** True when a backend URL is configured (used by the UI to explain an empty state). */
export function bookingsConfigured() {
  return API_BASE.length > 0;
}

async function api(path, init) {
  if (!API_BASE) {
    return {
      ok: false,
      status: 503,
      data: { error: 'The bookings backend is not configured (set BOOKINGS_API_URL or BACKEND_URL).' },
    };
  }
  try {
    const res = await fetch(`${API_BASE}${path}`, {
      ...init,
      cache: 'no-store',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...(init && init.headers) },
    });
    let data = null;
    try { data = await res.json(); } catch { /* empty / non-JSON body */ }
    return { ok: res.ok, status: res.status, data };
  } catch (err) {
    // Backend still booting or unreachable — never throw into the request.
    return { ok: false, status: 502, data: { error: String(err) } };
  }
}

/** Active bookable services (empty list on any failure). */
export async function getServices() {
  const r = await api('/api/bookings/services');
  return r.ok && Array.isArray(r.data) ? r.data : [];
}

/** Available (future) slots for a service (empty list on any failure). */
export async function getSlots(serviceId) {
  const r = await api(`/api/bookings/services/${encodeURIComponent(serviceId)}/slots`);
  return r.ok && Array.isArray(r.data) ? r.data : [];
}

/** Create a booking. Returns { ok, status, data } so callers can map status codes
 *  (409 = slot taken, 503 = unavailable, 400 = validation). */
export async function createBooking(payload) {
  return api('/api/bookings', { method: 'POST', body: JSON.stringify(payload) });
}
