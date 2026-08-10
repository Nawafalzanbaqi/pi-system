// whatsapp-integration — SERVER-SIDE client to the .NET backend for "__PROJECT_NAME__".
// =============================================================================
// On the fullstack base the .NET backend owns the swappable provider (mock |
// cloud_api) and the access token — it is the single source of truth. This helper
// runs on the Next.js server (Server Components / Route Handlers) and proxies to
// the backend's /api/whatsapp/send over the internal Docker network, so the token
// never reaches the browser. No dependencies — built-in fetch only.
//
// Base URL: BACKEND_URL (set by the fullstack base -> http://<name>-api:8080). With
// it unset the helper returns a clear error instead of throwing.
// =============================================================================

const API_BASE = (process.env.BACKEND_URL || '').replace(/\/+$/, '');

/** True when the backend URL is configured. */
export function whatsappConfigured() {
  return API_BASE.length > 0;
}

async function call(path, init) {
  if (!API_BASE) {
    return { success: false, provider: 'unknown', messageId: null, error: 'BACKEND_URL is not set.' };
  }
  try {
    const res = await fetch(`${API_BASE}${path}`, {
      ...init,
      cache: 'no-store',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json', ...(init && init.headers) },
    });
    let data = null;
    try { data = await res.json(); } catch { /* empty / non-JSON */ }
    return data ?? { success: res.ok, provider: 'unknown', messageId: null, error: res.ok ? null : `HTTP ${res.status}` };
  } catch (err) {
    return { success: false, provider: 'unknown', messageId: null, error: String(err) };
  }
}

/** Send a free-form text message. `to` is E.164 without '+', e.g. "9665XXXXXXXX". */
export function sendText(to, message) {
  return call('/api/whatsapp/send', { method: 'POST', body: JSON.stringify({ to, message }) });
}

/** Send a pre-approved template; `parameters` fill the body {{1}}, {{2}}, … in order. */
export function sendTemplate(to, template, language = 'en', parameters = []) {
  return call('/api/whatsapp/send', {
    method: 'POST',
    body: JSON.stringify({ to, template, language, parameters }),
  });
}

/** Active provider + readiness (provider, configured) from the backend. */
export async function whatsappStatus() {
  return call('/api/whatsapp/status', { method: 'GET' });
}
