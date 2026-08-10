// api-client.js — the panel's typed client for the control API.
// ===========================================================================
// SECURITY / TRANSPORT: the browser panel is same-origin with the API and is
// authorized by the httpOnly session cookie (BFF, see lib/auth/*) — the access
// token NEVER enters client JavaScript. So the default client sends the cookie
// (`credentials:'same-origin'`) and attaches NO bearer.
//
// The request SHAPING is split into a PURE `buildRequest()` that the unit tests
// drive: given a token it attaches `Authorization: Bearer <token>` (the API also
// accepts the header transport, used by programmatic clients), sets the JSON
// content-type only when there is a body, and never mutates global state. That is
// exactly what proves "method/path/body + bearer attached" without a browser.
//
// `apiFetch()` wraps fetch so a screen NEVER crashes on a failed call: it always
// resolves to { ok, status, data, error, unauthorized, forbidden }.

export const ENDPOINTS = {
  status: '/api/status',
  systemHealth: '/api/system-health',
  projects: '/api/projects',
  checks: '/api/checks',
  integrations: '/api/integrations',
  integrationKey: (key) => `/api/integrations/${encodeURIComponent(key)}`,
  action: (action) => `/api/actions/${encodeURIComponent(action)}`,
  restartService: '/api/actions/restart-service',
  createProject: '/api/projects',
  validateProject: '/api/projects?dryRun=1',
  // Read-only live feeds for the Monitoring + Growth views (part #4).
  monitoring: '/api/monitoring',
  monitoringAlerts: '/api/monitoring/alerts',
  backupStatus: '/api/backup-status',
  growthSeo: '/api/growth/seo',
  growthProspects: '/api/growth/prospects',
  growthAnalytics: '/api/growth/analytics',
  session: '/api/auth/session',
};

// PURE: turn a logical call into a concrete fetch spec. No I/O.
export function buildRequest({ method = 'GET', path, body, token, credentials = 'same-origin' } = {}) {
  if (typeof path !== 'string' || !path) throw new Error('buildRequest: path is required');
  const m = String(method).toUpperCase();
  const headers = { Accept: 'application/json' };
  const hasBody = body !== undefined && body !== null && m !== 'GET' && m !== 'HEAD';
  if (hasBody) headers['Content-Type'] = 'application/json';
  if (token) headers.Authorization = `Bearer ${token}`;
  const spec = { url: path, method: m, headers, credentials };
  if (hasBody) spec.body = JSON.stringify(body);
  return spec;
}

// Wrap fetch; normalize the {status:'ok',data} / {status:'error',error} envelope.
export async function apiFetch(opts, fetchImpl = (typeof fetch !== 'undefined' ? fetch : null)) {
  const spec = buildRequest(opts);
  if (!fetchImpl) return { ok: false, status: 0, error: 'fetch unavailable' };
  let res;
  try {
    res = await fetchImpl(spec.url, { method: spec.method, headers: spec.headers, credentials: spec.credentials, body: spec.body });
  } catch (e) {
    return { ok: false, status: 0, error: 'network error', detail: String(e?.message || e) };
  }
  let json = null;
  try { json = await res.json(); } catch { json = null; }
  const ok = res.ok && (!json || json.status !== 'error');
  return {
    ok,
    status: res.status,
    unauthorized: res.status === 401,
    forbidden: res.status === 403,
    data: json && json.status === 'ok' ? json.data : (ok ? json : undefined),
    error: ok ? undefined : (json?.error || `request failed (${res.status})`),
    raw: json,
  };
}

// A small client bound to an optional token (browser: none → cookie auth).
export function createClient({ token, fetchImpl } = {}) {
  const call = (method, path, body) => apiFetch({ method, path, body, token }, fetchImpl);
  return {
    get: (path) => call('GET', path),
    getStatus: () => call('GET', ENDPOINTS.status),
    getSystemHealth: () => call('GET', ENDPOINTS.systemHealth),
    getProjects: () => call('GET', ENDPOINTS.projects),
    getChecks: () => call('GET', ENDPOINTS.checks),
    // Read-only live feeds (Monitoring + Growth).
    getMonitoring: () => call('GET', ENDPOINTS.monitoring),
    getMonitoringAlerts: () => call('GET', ENDPOINTS.monitoringAlerts),
    getBackupStatus: () => call('GET', ENDPOINTS.backupStatus),
    getGrowthSeo: () => call('GET', ENDPOINTS.growthSeo),
    getGrowthProspects: () => call('GET', ENDPOINTS.growthProspects),
    getGrowthAnalytics: () => call('GET', ENDPOINTS.growthAnalytics),
    getIntegrations: () => call('GET', ENDPOINTS.integrations),
    setIntegrationKey: (key, value) => call('PUT', ENDPOINTS.integrationKey(key), { value }),
    runAction: (action, body) => call('POST', ENDPOINTS.action(action), body),
    restartService: (service) => call('POST', ENDPOINTS.restartService, { service }),
    // Securely scaffold a new project (operator-only on the server). `payload` is
    // the wizard's generate payload (name/preset/db/subdomain/locale/modules); the
    // server validates every field again, never overwrites, and audits.
    createProject: (payload) => call('POST', ENDPOINTS.createProject, payload),
    // Dry-run: validate + return what WOULD be created, without writing.
    validateProject: (payload) => call('POST', ENDPOINTS.validateProject, payload),
  };
}
