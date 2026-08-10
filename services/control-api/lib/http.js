// ===========================================================================
// pi-system Control API — JSON response helpers (clean envelope, no leaks)
// ---------------------------------------------------------------------------
// Every endpoint returns the SAME shape so a client can rely on it:
//   success -> { "status": "ok",    "data": <payload> }
//   failure -> { "status": "error", "error": "<safe message>" }
// Error messages are short and human — NEVER a stack trace, raw exception or any
// secret. Correct HTTP codes: 200 / 400 / 401 / 403 / 429 / 500.
// ===========================================================================

const SECURITY_HEADERS = {
  'Cache-Control': 'no-store',
  'X-Content-Type-Options': 'nosniff',
};

export function ok(data, status = 200) {
  return json(status, { status: 'ok', data });
}

export function fail(status, error, extra = {}) {
  return json(status, { status: 'error', error, ...extra });
}

export function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json; charset=utf-8', ...SECURITY_HEADERS },
  });
}

// 401 challenge for missing/invalid auth.
export function unauthorized(error = 'authentication required') {
  return json(401, { status: 'error', error });
}
export function forbidden(error = 'operator role required') {
  return fail(403, error);
}
export function tooMany(error = 'rate limit exceeded', retryAfterSec) {
  const res = fail(429, error);
  if (retryAfterSec) res.headers.set('Retry-After', String(retryAfterSec));
  return res;
}

// Map an internal failure to a SAFE 500 (the real error is logged server-side,
// never returned to the client).
export function serverError(error = 'internal error') {
  return fail(500, error);
}
