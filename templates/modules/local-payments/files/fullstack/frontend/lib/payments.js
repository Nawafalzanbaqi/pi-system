// local-payments — SERVER-SIDE client for the payment API on the .NET backend.
// =============================================================================
// SERVER-SIDE ONLY. The payment API (create / status / webhook / idempotent
// recording) runs on the .NET backend, which is on the internal Docker network with
// NO public port — the browser can never reach it directly. These helpers run on the
// Next.js server (Server Components + the Route Handlers under app/api/payments/) and
// proxy to the backend, keeping the API key + webhook handling server-side.
//
// No external dependencies — built-in fetch only.
//
// Base URL resolution (first non-empty wins):
//   1. PAYMENTS_API_URL  explicit override — set this for a nextjs-app base that
//                        pairs with a SEPARATE .NET payments backend (and pass it
//                        into the web container; see the module README).
//   2. BACKEND_URL       set by the fullstack base -> http://<name>-api:8080.
// With neither set (a plain nextjs-app with no backend wired yet) the helpers return
// a clear 503 instead of throwing, so the UI degrades gracefully.
// =============================================================================

const API_BASE = (process.env.PAYMENTS_API_URL || process.env.BACKEND_URL || '').replace(/\/+$/, '');

/** True when a payments backend URL is configured (UI uses this to explain empty state). */
export function paymentsConfigured() {
  return API_BASE.length > 0;
}

export function paymentsApiBase() {
  return API_BASE;
}

async function call(path, init) {
  if (!API_BASE) {
    return {
      ok: false,
      status: 503,
      data: { error: 'The payments backend is not configured (set PAYMENTS_API_URL or BACKEND_URL).' },
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
    return { ok: false, status: 502, data: { error: String(err) } };
  }
}

/** Create a payment intent. Returns { ok, status, data } where data has
 *  { reference, provider, status, redirectUrl, mockPayUrl }. Amount is in the
 *  currency's minor unit (e.g. halalas for SAR). */
export function createPayment(payload) {
  return call('/api/payments', { method: 'POST', body: JSON.stringify(payload) });
}

/** Current status of a payment by its public reference. */
export function getPayment(reference) {
  return call(`/api/payments/${encodeURIComponent(reference)}`, { method: 'GET' });
}

/** Mock provider only: simulate paying a created intent (triggers the signed webhook). */
export function mockPay(reference) {
  return call(`/api/payments/mock/pay/${encodeURIComponent(reference)}`, { method: 'POST' });
}

/** Active provider + readiness from the backend (provider, configured, databaseReady). */
export function paymentsStatus() {
  return call('/api/payments/_status', { method: 'GET' });
}
