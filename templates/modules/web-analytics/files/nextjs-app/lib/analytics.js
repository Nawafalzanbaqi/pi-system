// web-analytics — privacy-first analytics config + helpers (pi-system module).
//
// Points ONLY at your self-hosted analytics service (Umami at
// analytics.<BASE_DOMAIN>) — no Google Analytics, no third-party tracker, no data
// ever leaves the platform. Everything here is ENV-GATED: with the two env vars
// unset there is no script, no network calls, nothing.
//
// Read at render time from the container environment (set by this module's compose
// fragment from .env). These are NOT NEXT_PUBLIC_ vars: the snippet is emitted by a
// server component, so the values are read on the server and written into the HTML —
// they are never bundled into client JS.
//
//   ANALYTICS_SCRIPT_URL  the tracker URL, e.g. https://analytics.<domain>/script.js
//   ANALYTICS_SITE_ID     this site's "website id" from the Umami dashboard
//
// Pure JavaScript — no external dependencies (ARM64-safe, no credentials).

// Resolve the analytics config from an environment object (defaults to
// process.env). Returns null UNLESS BOTH values are present and non-empty — this
// single predicate is the env-gate the whole module hinges on (no config => no
// tracking). Exposed with an injectable `env` so it is unit-testable without a
// running server.
export function analyticsConfig(env = process.env) {
  const scriptUrl = String(env.ANALYTICS_SCRIPT_URL || '').trim();
  const siteId = String(env.ANALYTICS_SITE_ID || '').trim();
  if (!scriptUrl || !siteId) return null;
  return { scriptUrl, siteId };
}

// Convenience boolean mirror of the gate above.
export function isAnalyticsEnabled(env = process.env) {
  return analyticsConfig(env) !== null;
}

// Client-side CUSTOM EVENT helper. Call it from a Client Component (e.g. an
// onClick handler) to record a click / conversion / outbound link:
//
//   'use client';
//   import { trackEvent } from '@/lib/analytics';   // or a relative import
//   <button onClick={() => trackEvent('signup-click', { plan: 'pro' })}>…</button>
//
// It is a SAFE NO-OP when the tracker is absent (analytics disabled, script not yet
// loaded, or running on the server), so it never throws and needs no env itself —
// it talks to the umami runtime the tracker script installs on `window`.
export function trackEvent(name, data) {
  if (typeof window === 'undefined') return;
  const umami = window.umami;
  if (!umami || typeof umami.track !== 'function') return;
  if (data && typeof data === 'object') umami.track(name, data);
  else umami.track(name);
}
