// control-panel — OIDC Relying Party (Authorization Code + PKCE). SERVER-SIDE ONLY.
// ===========================================================================
// Mirrors the platform's auth-sso module conventions: openid-client v5 (pure JS
// → ARM64-safe, pinned), every setting from env, NO secrets in code. This is the
// BROWSER login flow for the panel; the access token it obtains is sealed into an
// httpOnly session cookie (lib/auth/session.js) and the SAME token is what the
// existing API routes verify (jose JWKS) — so logging in here grants exactly the
// Keycloak-scoped access the API already enforced, nothing more.
//
// Reuses the API's existing CONTROL_API_OIDC_ISSUER (the realm). Adds the RP
// client settings (client id/secret, redirect, app base url, scope) — all empty
// templates under the CONTROL API section of .env.example; the Keycloak client
// creation stays a documented, DEFERRED one-time step.
import { Issuer, generators } from 'openid-client';

export const oidcConfig = {
  issuerUrl: (process.env.CONTROL_API_OIDC_ISSUER || '').trim(),
  clientId: (process.env.CONTROL_API_OIDC_CLIENT_ID || '').trim(),
  clientSecret: (process.env.CONTROL_API_OIDC_CLIENT_SECRET || '').trim(),
  redirectUri: (process.env.CONTROL_API_OIDC_REDIRECT_URI || '').trim(),
  postLogoutRedirectUri: (process.env.CONTROL_API_OIDC_POST_LOGOUT_REDIRECT_URI || '').trim(),
  appBaseUrl: (process.env.CONTROL_API_OIDC_APP_BASE_URL || '').trim(),
  scope: (process.env.CONTROL_API_OIDC_SCOPE || 'openid profile email').trim(),
};

/** True only when the minimum needed to START a panel login is present. Blank =>
 *  login is OFF; the /api/auth/* routes report 503 and the page shows a clear
 *  "not configured yet" gate (the rest of the service is unaffected). */
export function oidcConfigured() {
  return Boolean(oidcConfig.issuerUrl && oidcConfig.clientId && oidcConfig.redirectUri);
}

let _clientPromise = null;

/** Discover the realm and build a memoized OIDC client (one discovery per process;
 *  cached, reset on failure so the next request retries). */
export async function getClient() {
  if (!oidcConfigured()) {
    throw new Error('Control-panel OIDC not configured (need CONTROL_API_OIDC_ISSUER, CONTROL_API_OIDC_CLIENT_ID and the redirect URI).');
  }
  if (!_clientPromise) {
    _clientPromise = (async () => {
      const issuer = await Issuer.discover(oidcConfig.issuerUrl);
      return new issuer.Client({
        client_id: oidcConfig.clientId,
        client_secret: oidcConfig.clientSecret || undefined,
        redirect_uris: [oidcConfig.redirectUri],
        post_logout_redirect_uris: oidcConfig.postLogoutRedirectUri ? [oidcConfig.postLogoutRedirectUri] : [],
        response_types: ['code'],
        // Confidential client (has a secret) -> Basic auth at the token endpoint.
        // Public client (no secret) -> PKCE alone protects the code exchange.
        token_endpoint_auth_method: oidcConfig.clientSecret ? 'client_secret_basic' : 'none',
      });
    })().catch((err) => { _clientPromise = null; throw err; });
  }
  return _clientPromise;
}

export { generators };
