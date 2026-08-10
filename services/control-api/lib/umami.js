// ===========================================================================
// pi-system Control API — UMAMI analytics summary (server-side, read-only)
// ---------------------------------------------------------------------------
// The privacy-first web-analytics summary for the Growth view. We query the
// SELF-HOSTED Umami over the INTERNAL Docker network from the API container
// (http://umami:3000) — its credentials live ONLY in this server's env and are
// NEVER returned to the browser; the browser only ever receives the aggregated,
// cookie-less numbers. This is lighter + safer than scraping Umami's Postgres
// directly, and it reuses Umami's own privacy-first aggregates.
//
// If analytics is not configured (env not set) we return { configured:false } so
// the panel shows a clean "not configured" state — never an error. If it is
// configured but unreachable we return { configured:true, ok:false, error } so
// the panel shows an error state. All numeric shaping happens in adaptAnalytics.
//
// PURE-ish: fetch is injected (deps.fetch) so tests drive it with canned Umami
// responses and never touch the network.
// ===========================================================================

export function isAnalyticsConfigured(a) {
  return !!(a && a.umamiUrl && a.username && a.password && a.websiteId);
}

const DAY_MS = 86400000;

export async function fetchUmamiSummary(config, deps = {}) {
  const a = config && config.analytics ? config.analytics : {};
  if (!isAnalyticsConfigured(a)) return { configured: false };

  const fetchImpl = deps.fetch || (typeof fetch !== 'undefined' ? fetch : null);
  if (!fetchImpl) return { configured: true, ok: false, error: 'fetch unavailable' };
  const now = typeof deps.now === 'number' ? deps.now : Date.now();
  const base = String(a.umamiUrl).replace(/\/$/, '');
  const id = encodeURIComponent(a.websiteId);
  const endAt = now;
  const startAt = now - 7 * DAY_MS;
  const timeoutMs = a.timeoutMs || 8000;

  const ctl = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timer = ctl ? setTimeout(() => ctl.abort(), timeoutMs) : null;

  try {
    // 1) Authenticate (token stays server-side).
    const loginRes = await fetchImpl(`${base}/api/auth/login`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ username: a.username, password: a.password }),
      signal: ctl ? ctl.signal : undefined,
    });
    if (!loginRes.ok) return { configured: true, ok: false, error: `umami login failed (${loginRes.status})` };
    const loginJson = await loginRes.json().catch(() => null);
    const token = loginJson && loginJson.token;
    if (!token) return { configured: true, ok: false, error: 'umami login returned no token' };

    const auth = { Authorization: `Bearer ${token}`, Accept: 'application/json' };
    const q = `startAt=${startAt}&endAt=${endAt}`;
    const getJson = async (path) => {
      const r = await fetchImpl(`${base}${path}`, { headers: auth, signal: ctl ? ctl.signal : undefined });
      if (!r.ok) throw new Error(`umami ${path} -> ${r.status}`);
      return r.json();
    };

    // 2) Aggregates (Umami returns {value, prev} comparing to the prior period).
    const [stats, pv, urls, referrers, countries] = await Promise.all([
      getJson(`/api/websites/${id}/stats?${q}`),
      getJson(`/api/websites/${id}/pageviews?${q}&unit=day&timezone=UTC`),
      getJson(`/api/websites/${id}/metrics?type=url&${q}&limit=5`),
      getJson(`/api/websites/${id}/metrics?type=referrer&${q}&limit=6`),
      getJson(`/api/websites/${id}/metrics?type=country&${q}&limit=5`),
    ]);

    const visitors = stats && stats.visitors ? stats.visitors : {};
    const series = pv && Array.isArray(pv.sessions) ? pv.sessions
      : (pv && Array.isArray(pv.pageviews) ? pv.pageviews : []);

    return {
      configured: true,
      ok: true,
      raw: {
        visitors: numOr(visitors.value, 0),
        prevVisitors: numOr(visitors.prev, 0),
        series: series.map((p) => numOr(p && p.y, 0)),
        urls: Array.isArray(urls) ? urls : [],
        referrers: Array.isArray(referrers) ? referrers : [],
        countries: Array.isArray(countries) ? countries : [],
      },
    };
  } catch (e) {
    const msg = e && e.name === 'AbortError' ? 'umami timed out' : 'umami unreachable';
    return { configured: true, ok: false, error: msg };
  } finally {
    if (timer) clearTimeout(timer);
  }
}

function numOr(v, d) { const n = Number(v); return Number.isFinite(n) ? n : d; }
