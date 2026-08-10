// web-analytics — the env-gated tracking snippet (pi-system module).
//
// A SERVER component that emits the privacy-first Umami tracker for THIS site, or
// renders nothing when analytics is not configured. It is the single place the
// tracking <script> is injected, and it is rendered once from the root template so
// it covers every page.
//
// Why a server component + `next/script`:
//   * Server component  -> the site id / script URL are read on the server and
//     written into the HTML; they are never bundled into client JS.
//   * next/script (afterInteractive, stable id) -> the tracker is loaded EXACTLY
//     ONCE per session and de-duplicated across App-Router client navigations, so
//     the root template re-rendering on navigation can never double-load it.
//
// PRIVACY: the only thing this loads is YOUR self-hosted tracker. Umami sets no
// cookies and collects no personal data by default.
import Script from 'next/script';
import { headers } from 'next/headers';
import { analyticsConfig } from '../lib/analytics';

export default async function Analytics() {
  // Force request-time (dynamic) rendering so the RUNTIME container env — set from
  // .env by this module's compose fragment — is what we read, not the build-time
  // environment (which has no analytics values). Without this a statically rendered
  // page would bake in "disabled". The header value itself is intentionally unused.
  await headers();

  const cfg = analyticsConfig();
  if (!cfg) return null; // ENV-GATE: not configured => no snippet, no tracking.

  return (
    <Script
      id="pi-analytics"
      src={cfg.scriptUrl}
      data-website-id={cfg.siteId}
      strategy="afterInteractive"
    />
  );
}
