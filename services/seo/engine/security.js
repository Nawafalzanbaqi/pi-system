// pi-system SEO engine — HTTP response-header SECURITY checks + scoring (pure).
// ===========================================================================
// The probe (probe.js) already collects the main page's response headers as
// res.headers. This module turns those headers into a deterministic SECURITY
// checks object, a 0..100 score, and a set of CLIENT-FACING findings — the same
// shape and discipline as scoring.js (documented deductions) and rules.js
// (prioritised {id, priority, category, ...} findings).
//
// WHY it lives in the SEO engine: a missing padlock or a frameable login page is
// exactly the kind of thing a freelancer points at when pitching a site refresh —
// it is a trust/sales problem first and a "security header" second. So the findings
// here are deliberately phrased as plain talking points a business owner (and their
// customers) would care about, NOT as RFC jargon.
//
// Everything here is PURE and DEPENDENCY-FREE: same headers => same checks => same
// score => same findings. The only input is the header set, normalised first by
// headersToObject so a Fetch Headers instance, a Map, or a plain object all work —
// which keeps the whole module unit-testable with no network and no browser.
// ===========================================================================

// Documented score deductions — the single source of truth so a finding and the
// score never disagree (mirrors scoring.js's THRESHOLDS). Each is points off 100.
export const SECURITY_DEDUCTIONS = {
  https: 40,        // not served over HTTPS — undermines everything below it
  csp: 15,          // no Content-Security-Policy (no defence against injected code)
  hsts: 12,         // no HTTP Strict-Transport-Security (first request can downgrade)
  noSniff: 8,       // no X-Content-Type-Options: nosniff (browser MIME-guessing)
  clickjacking: 8,  // no X-Frame-Options AND no CSP frame-ancestors (framing attacks)
  referrer: 4,      // no Referrer-Policy (leaks where visitors came from)
  permissions: 3,   // no Permissions-Policy (camera/mic/location not locked down)
  disclosure: 3,    // Server / X-Powered-By advertises software versions
  cookie: 6,        // a Set-Cookie missing Secure / HttpOnly / SameSite
};

// HSTS shorter than this is too brief to be worth advertising as "real" HSTS.
const HSTS_MIN_MAXAGE = 15552000; // 180 days, in seconds

const clamp = (n) => Math.max(0, Math.min(100, Math.round(n)));

// ---------------------------------------------------------------------------
// headersToObject(headers) -> { lowercased-name: string-value }
//   Accepts a Fetch Headers instance OR a Map (both expose forEach(value, key))
//   OR a plain object. Header names are lowercased so lookups are case-insensitive.
//   Never throws; an empty/absent header set yields {}.
// ---------------------------------------------------------------------------
export function headersToObject(headers) {
  const out = {};
  if (!headers) return out;
  const put = (key, value) => {
    if (key == null) return;
    out[String(key).toLowerCase()] = value == null ? '' : String(value);
  };
  // Fetch Headers AND Map both iterate as forEach((value, key) => ...).
  if (typeof headers.forEach === 'function') {
    headers.forEach((value, key) => put(key, value));
    return out;
  }
  // Plain object.
  if (typeof headers === 'object') {
    for (const key of Object.keys(headers)) put(key, headers[key]);
  }
  return out;
}

// Pull the integer max-age out of an HSTS header value, or null if absent.
function parseMaxAge(value) {
  if (!value) return null;
  const m = /max-age\s*=\s*"?(\d+)"?/i.exec(String(value));
  return m ? Number(m[1]) : null;
}

// Does this header value broadcast a software version (e.g. "nginx/1.18.0")?
function revealsVersion(value) {
  if (!value) return false;
  return /\/\s*\d/.test(value) || /\d+\.\d+/.test(value);
}

// ---------------------------------------------------------------------------
// analyzeSecurity(headers, {https}) -> the deterministic SECURITY checks object.
//   `https` says whether the audited URL was https (the probe already knows this).
// Pure: same headers + https => same output. No network, no clock, no randomness.
// ---------------------------------------------------------------------------
export function analyzeSecurity(headers, { https = false } = {}) {
  const h = headersToObject(headers);
  const get = (name) => (name in h ? h[name] : null);

  // HSTS — present only counts when it actually enforces (max-age > 0).
  const stsRaw = get('strict-transport-security');
  const maxAge = parseMaxAge(stsRaw);
  const hsts = {
    present: stsRaw !== null && maxAge !== null && maxAge > 0,
    maxAge,
    longEnough: maxAge !== null && maxAge >= HSTS_MIN_MAXAGE,
  };

  // Content-Security-Policy — present + whether it constrains framing.
  const cspRaw = get('content-security-policy');
  const csp = {
    present: cspRaw !== null && cspRaw.trim().length > 0,
    frameAncestors: cspRaw !== null && /(?:^|;)\s*frame-ancestors\b/i.test(cspRaw),
  };

  // X-Content-Type-Options: nosniff.
  const noSniff = (get('x-content-type-options') || '').toLowerCase().includes('nosniff');

  // Clickjacking protection: X-Frame-Options OR a CSP frame-ancestors directive.
  const xfo = get('x-frame-options');
  const clickjacking = {
    protected: (xfo !== null && xfo.trim().length > 0) || csp.frameAncestors,
    xFrameOptions: xfo,
    frameAncestors: csp.frameAncestors,
  };

  // Referrer-Policy.
  const refRaw = get('referrer-policy');
  const referrerPolicy = { present: refRaw !== null && refRaw.trim().length > 0, value: refRaw };

  // Permissions-Policy (accept the legacy Feature-Policy header too).
  const permRaw = get('permissions-policy') ?? get('feature-policy');
  const permissionsPolicy = { present: permRaw !== null && permRaw.trim().length > 0 };

  // Version disclosure via Server / X-Powered-By. Any X-Powered-By is a leak; a
  // Server header only counts when it carries a version number (e.g. "nginx/1.18").
  const server = get('server');
  const poweredBy = get('x-powered-by');
  const disclosure = {
    server,
    poweredBy,
    disclosed: poweredBy !== null || revealsVersion(server),
  };

  // Set-Cookie hardening. Best-effort over the (possibly combined) header value:
  // attribute flags always follow a ';', so they won't be confused with a value.
  const cookieRaw = get('set-cookie');
  const cookiePresent = cookieRaw !== null && cookieRaw.length > 0;
  const cookies = {
    present: cookiePresent,
    secure: cookiePresent && /;\s*secure\b/i.test(cookieRaw),
    httpOnly: cookiePresent && /;\s*httponly\b/i.test(cookieRaw),
    sameSite: cookiePresent && /;\s*samesite\s*=/i.test(cookieRaw),
    hardened: false,
  };
  cookies.hardened = cookiePresent && cookies.secure && cookies.httpOnly && cookies.sameSite;

  return {
    https: Boolean(https),
    hsts,
    csp,
    noSniff,
    clickjacking,
    referrerPolicy,
    permissionsPolicy,
    disclosure,
    cookies,
  };
}

// ---------------------------------------------------------------------------
// securityScore(sec) -> 0..100 from the checks object, using SECURITY_DEDUCTIONS.
// Deterministic; tolerant of a partial checks object (a missing sub-check counts
// as "header absent" and is deducted, fail-closed like the rest of the engine).
// ---------------------------------------------------------------------------
export function securityScore(sec) {
  const s = sec || {};
  let score = 100;
  if (!s.https) score -= SECURITY_DEDUCTIONS.https;
  if (!s.csp?.present) score -= SECURITY_DEDUCTIONS.csp;
  if (!s.hsts?.present) score -= SECURITY_DEDUCTIONS.hsts;
  if (!s.noSniff) score -= SECURITY_DEDUCTIONS.noSniff;
  if (!s.clickjacking?.protected) score -= SECURITY_DEDUCTIONS.clickjacking;
  if (!s.referrerPolicy?.present) score -= SECURITY_DEDUCTIONS.referrer;
  if (!s.permissionsPolicy?.present) score -= SECURITY_DEDUCTIONS.permissions;
  if (s.disclosure?.disclosed) score -= SECURITY_DEDUCTIONS.disclosure;
  if (s.cookies?.present && !s.cookies.hardened) score -= SECURITY_DEDUCTIONS.cookie;
  return clamp(score);
}

// Build a finding with the stable shape rules.js uses; category is always 'security'.
function f(id, priority, title, detail, recommendation) {
  return { id, priority, category: 'security', title, detail, recommendation };
}

// ---------------------------------------------------------------------------
// securityFindings(audit) -> prioritised, CLIENT-FACING findings (security only).
//   Reads the security checks the probe stored at audit.checks.security. Returns []
//   when there is nothing to inspect (e.g. an unreachable site recorded no headers).
//   Emitted critical-first so the list reads as a ready-made set of talking points.
// ---------------------------------------------------------------------------
export function securityFindings(audit) {
  const out = [];
  const sec = (audit && audit.checks && audit.checks.security) || null;
  if (!sec) return out;

  // --- Critical: the padlock itself ----------------------------------------
  if (!sec.https) {
    out.push(f(
      'security-no-https', 'critical',
      'Add the padlock — your site is not on a secure (HTTPS) connection',
      'Browsers label sites without HTTPS as "Not secure", and most visitors leave the moment they see that warning — especially before entering a phone number, a card, or a password. It also quietly lowers your Google ranking.',
      'Serve the whole site over HTTPS with a free, auto-renewing certificate (Caddy issues and renews these automatically) so every visitor sees the trusted padlock.',
    ));
  }

  // --- High: code injection + impersonation --------------------------------
  if (!sec.csp?.present) {
    out.push(f(
      'security-no-csp', 'high',
      'Lock the front door — nothing limits what code can run on your pages',
      'Without a content-security policy, a single compromised script, plugin, or ad can run hostile code on your pages — quietly skimming customer details or defacing the site — and you would be the last to know.',
      'Add a Content-Security-Policy that only allows scripts and styles from sources you trust, so injected code simply cannot run.',
    ));
  }
  if (!sec.clickjacking?.protected) {
    out.push(f(
      'security-clickjacking', 'high',
      'Stop scammers from framing your site as their own',
      'Nothing currently stops a scam site from loading your pages invisibly inside theirs and tricking your customers into clicking things they never meant to — a "clickjacking" trick that lands on your brand.',
      'Tell browsers to refuse to embed your site elsewhere (an X-Frame-Options / CSP frame-ancestors rule) so only you can display your pages.',
    ));
  }

  // --- Medium: connection stickiness, cookies, MIME guessing ----------------
  if (sec.https && !sec.hsts?.present) {
    out.push(f(
      'security-no-hsts', 'medium',
      'Make the secure connection stick',
      'Your site supports HTTPS, but a visitor\'s first request can still be quietly downgraded to an unencrypted one — the gap attackers on shared/public Wi-Fi use to read or tamper with traffic.',
      'Add an HSTS header so browsers always use the secure version of your site, from the very first visit.',
    ));
  }
  if (sec.cookies?.present && !sec.cookies.hardened) {
    out.push(f(
      'security-insecure-cookies', 'medium',
      'Protect the cookies that keep customers logged in',
      'The site sets cookies (for logins or carts) without the full set of safety flags, leaving them easier to steal or hijack — which can mean someone taking over a customer\'s account.',
      'Mark cookies Secure, HttpOnly and SameSite so they cannot be read by scripts or sent over an insecure connection.',
    ));
  }
  if (!sec.noSniff) {
    out.push(f(
      'security-no-nosniff', 'medium',
      'Stop the browser from guessing what files are',
      'Browsers are currently allowed to guess what each file is, which attackers exploit to make a harmless-looking upload run as code on your visitors\' machines.',
      'Add the X-Content-Type-Options: nosniff header so browsers treat every file exactly as you intend.',
    ));
  }

  // --- Low: privacy, device features, version chatter -----------------------
  if (!sec.referrerPolicy?.present) {
    out.push(f(
      'security-no-referrer-policy', 'low',
      'Keep your visitors\' browsing private',
      'When someone clicks a link off your site, their browser can hand the other site the exact page they came from — leaking customer behaviour you would rather keep to yourself.',
      'Set a Referrer-Policy so only the minimum necessary information is shared when visitors follow outbound links.',
    ));
  }
  if (!sec.permissionsPolicy?.present) {
    out.push(f(
      'security-no-permissions-policy', 'low',
      'Lock down camera, microphone and location access',
      'Your pages do not restrict powerful browser features, so any embedded or injected content could try to request a visitor\'s camera, microphone, or location — an easy way to lose their trust.',
      'Add a Permissions-Policy that switches off the device features your site does not actually use.',
    ));
  }
  if (sec.disclosure?.disclosed) {
    const bits = [];
    if (sec.disclosure.server) bits.push(`Server: ${sec.disclosure.server}`);
    if (sec.disclosure.poweredBy) bits.push(`X-Powered-By: ${sec.disclosure.poweredBy}`);
    const shown = bits.length ? ` (it currently sends ${bits.join(' and ')})` : '';
    out.push(f(
      'security-version-disclosure', 'low',
      'Stop advertising exactly what your site runs on',
      `Your site's responses announce the software and version it runs on${shown}, which hands attackers a ready-made list of known weaknesses to try against it.`,
      'Remove or trim those version labels (Server / X-Powered-By) so the underlying software is not broadcast to everyone.',
    ));
  }

  return out;
}
