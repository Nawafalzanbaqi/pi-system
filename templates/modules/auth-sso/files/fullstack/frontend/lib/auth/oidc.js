// auth-sso — OIDC Relying Party (Authorization Code + PKCE). SERVER-SIDE ONLY.
// =============================================================================
// Uses `openid-client` — a spec-compliant, pure-JavaScript OIDC client (no native
// modules -> ARM64-safe), pinned in package.json. Every setting comes from env
// (injected by the auth-sso compose fragment from this project's .env slots); this
// file contains NO secrets.
//
// Why openid-client (+ jose for the session) instead of a batteries-included
// library: it keeps the platform's "pinned, reproducible, never-latest" guarantee
// (stable releases, no beta), it is tiny and dependency-light, and it makes the
// Authorization Code + PKCE exchange explicit and auditable. openid-client v6 is
// the eventual upgrade path (a functional API); v5's class API is used here.
// =============================================================================
import { Issuer, generators } from 'openid-client';

export const oidcConfig = {
  issuerUrl: (process.env.OIDC_ISSUER_URL || '').trim(),
  clientId: (process.env.OIDC_CLIENT_ID || '').trim(),
  clientSecret: (process.env.OIDC_CLIENT_SECRET || '').trim(),
  redirectUri: (process.env.OIDC_REDIRECT_URI || '').trim(),
  postLogoutRedirectUri: (process.env.OIDC_POST_LOGOUT_REDIRECT_URI || '').trim(),
  appBaseUrl: (process.env.OIDC_APP_BASE_URL || '').trim(),
  scope: (process.env.OIDC_SCOPE || 'openid profile email').trim(),
};

/** True only when the minimum needed to START a login is present. Blank => auth is
 *  OFF and the /api/auth/* routes report 503 (the rest of the app is unaffected). */
export function oidcConfigured() {
  return Boolean(oidcConfig.issuerUrl && oidcConfig.clientId && oidcConfig.redirectUri);
}

let _clientPromise = null;

/** Discover the realm and build a memoized OIDC client (one discovery per process;
 *  the result is cached, and reset on failure so the next request retries). */
export async function getClient() {
  if (!oidcConfigured()) {
    throw new Error('OIDC not configured (need OIDC_ISSUER_URL, OIDC_CLIENT_ID and the redirect URI).');
  }
  if (!_clientPromise) {
    _clientPromise = (async () => {
      const issuer = await Issuer.discover(oidcConfig.issuerUrl);
      return new issuer.Client({
        client_id: oidcConfig.clientId,
        client_secret: oidcConfig.clientSecret || undefined,
        redirect_uris: [oidcConfig.redirectUri],
        post_logout_redirect_uris: oidcConfig.postLogoutRedirectUri
          ? [oidcConfig.postLogoutRedirectUri]
          : [],
        response_types: ['code'],
        // Confidential client (has a secret) -> Basic auth at the token endpoint.
        // Public client (no secret) -> PKCE alone protects the code exchange.
        token_endpoint_auth_method: oidcConfig.clientSecret ? 'client_secret_basic' : 'none',
      });
    })().catch((err) => {
      _clientPromise = null;
      throw err;
    });
  }
  return _clientPromise;
}

export { generators };
