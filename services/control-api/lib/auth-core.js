// ===========================================================================
// pi-system Control API — AUTHORIZATION CORE (PURE — no jose, no network)
// ---------------------------------------------------------------------------
// The deterministic security decision, split out from the JWKS signature check
// (lib/verify-token.js, the seam) so the WHOLE authorization matrix is testable
// with raw `node` and synthetic payloads — no Keycloak, no network:
//
//   * extractBearer   pull the token from an Authorization header (pure parse).
//   * hasOperatorRole given an already-VERIFIED token payload + config, is the
//                     caller an operator? Looks in realm_access.roles AND
//                     resource_access[audience].roles (Keycloak's two role homes).
//   * evaluateAuth    the gate every route uses:
//                       no payload                      -> 401 (unauthenticated)
//                       payload, write/action, no role  -> 403 (forbidden)
//                       otherwise                       -> 200 (allowed)
//
// SECURITY: this NEVER trusts an unverified token. evaluateAuth must be called
// with a payload that lib/verify-token.js already validated (signature, issuer,
// audience, expiry); a null payload always means "deny / 401".
// ===========================================================================

// Parse "Authorization: Bearer <token>" -> the token, or null. Case-insensitive
// scheme; rejects empty/malformed headers.
export function extractBearer(headerValue) {
  if (typeof headerValue !== 'string') return null;
  const m = headerValue.match(/^\s*Bearer\s+([A-Za-z0-9._~+/-]+=*)\s*$/i);
  return m ? m[1] : null;
}

// Collect the role names a verified payload carries (Keycloak puts realm roles in
// realm_access.roles and client roles in resource_access.<client>.roles).
export function rolesOf(payload, config = {}) {
  const roles = new Set();
  const add = (arr) => { if (Array.isArray(arr)) for (const r of arr) if (typeof r === 'string') roles.add(r); };
  if (payload && typeof payload === 'object') {
    add(payload.realm_access?.roles);
    const ra = payload.resource_access;
    if (ra && typeof ra === 'object') {
      // The configured audience/client first, then any client (operator role is
      // unique enough that scanning is safe and avoids brittle client-id coupling).
      if (config.audience && ra[config.audience]) add(ra[config.audience].roles);
      for (const client of Object.keys(ra)) add(ra[client]?.roles);
    }
    // Some setups flatten roles into a top-level "roles" claim.
    add(payload.roles);
  }
  return roles;
}

export function hasOperatorRole(payload, config = {}) {
  const role = config.operatorRole || 'operator';
  return rolesOf(payload, config).has(role);
}

// The single decision used by every protected route.
// requireOperator=true for state-changing / config-writing endpoints.
export function evaluateAuth({ payload, config = {}, requireOperator = false }) {
  if (!payload || typeof payload !== 'object') {
    return { ok: false, status: 401, error: 'authentication required' };
  }
  if (requireOperator && !hasOperatorRole(payload, config)) {
    return { ok: false, status: 403, error: 'operator role required' };
  }
  return { ok: true, status: 200 };
}

// A stable, NON-secret identity label for the audit log (never the raw token).
export function identityOf(payload) {
  if (!payload || typeof payload !== 'object') return 'anonymous';
  return (
    payload.preferred_username ||
    payload.email ||
    payload.sub ||
    'unknown'
  );
}
