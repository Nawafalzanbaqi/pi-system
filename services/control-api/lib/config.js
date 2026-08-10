// ===========================================================================
// pi-system Control API — runtime CONFIG from environment (PURE given env)
// ---------------------------------------------------------------------------
// All Control API configuration comes from environment variables (documented as
// empty templates in the CONTROL API section of .env.example). NOTHING here is a
// secret value the manager edits — these configure the API itself (its OIDC trust
// anchors, the constrained execution bridge, file paths, throttling).
//
// getConfig(env=process.env) is pure: same env in -> same config out, so tests
// can build a config without any ambient environment.
// ===========================================================================
import { DEFAULT_AUDIT_MAX_LINES } from './audit.js';

export function getConfig(env = process.env) {
  const issuer = str(env.CONTROL_API_OIDC_ISSUER);
  return {
    // --- Keycloak / OIDC trust anchors ------------------------------------
    issuer,
    audience: str(env.CONTROL_API_OIDC_AUDIENCE),
    // JWKS defaults to the standard Keycloak path under the issuer when not set.
    jwksUri: str(env.CONTROL_API_OIDC_JWKS_URI) ||
      (issuer ? `${issuer.replace(/\/$/, '')}/protocol/openid-connect/certs` : ''),
    operatorRole: str(env.CONTROL_API_OPERATOR_ROLE) || 'operator',

    // --- The .env this API manages + where backups/audit live -------------
    envFile: str(env.CONTROL_API_ENV_FILE) || '/workspace/.env',
    envExample: str(env.CONTROL_API_ENV_EXAMPLE) || '/workspace/.env.example',
    backupDir: str(env.CONTROL_API_BACKUP_DIR) || '/workspace/data/control-api/env-backups',
    auditLog: str(env.CONTROL_API_AUDIT_LOG) || '/workspace/data/control-api/audit.log',
    // Line cap for the audit log's self-trim (see audit.js). 0 disables trimming.
    auditMaxLines: intZeroOk(env.CONTROL_API_AUDIT_MAX_LINES, DEFAULT_AUDIT_MAX_LINES),

    // --- Constrained execution bridge (SSH forced-command, like the bot) ---
    bridge: {
      mode: str(env.CONTROL_API_BRIDGE_MODE) || 'ssh',   // ssh | local (dev/tests)
      host: str(env.CONTROL_API_BRIDGE_SSH_HOST),
      user: str(env.CONTROL_API_BRIDGE_SSH_USER),
      port: str(env.CONTROL_API_BRIDGE_SSH_PORT) || '22',
      key: str(env.CONTROL_API_BRIDGE_SSH_KEY) || '/app/secrets/bridge_key',
      // Only used in mode=local (an explicitly mounted bot-exec.sh, e.g. dev).
      botExec: str(env.CONTROL_API_BRIDGE_BOT_EXEC),
      timeoutMs: int(env.CONTROL_API_BRIDGE_TIMEOUT_MS, 120000),
    },

    // --- Project GENERATION bridge (its OWN dedicated forced-command key) ----
    // Project creation reaches the host through the SIBLING bot-exec-generate.sh,
    // pinned to a SEPARATE key (one key = one forced command). Host/user/port fall
    // back to the main bridge's (same Pi) when not set; the key MUST be its own.
    // The default timeout is larger — scaffolding + compose validation is slower.
    generateBridge: {
      mode: str(env.CONTROL_API_GENERATE_BRIDGE_MODE) || str(env.CONTROL_API_BRIDGE_MODE) || 'ssh',
      host: str(env.CONTROL_API_GENERATE_BRIDGE_SSH_HOST) || str(env.CONTROL_API_BRIDGE_SSH_HOST),
      user: str(env.CONTROL_API_GENERATE_BRIDGE_SSH_USER) || str(env.CONTROL_API_BRIDGE_SSH_USER),
      port: str(env.CONTROL_API_GENERATE_BRIDGE_SSH_PORT) || str(env.CONTROL_API_BRIDGE_SSH_PORT) || '22',
      key: str(env.CONTROL_API_GENERATE_BRIDGE_SSH_KEY) || '/app/secrets/generate_bridge_key',
      // Only used in mode=local (an explicitly mounted bot-exec-generate.sh, e.g. dev/tests).
      botExec: str(env.CONTROL_API_GENERATE_BRIDGE_EXEC),
      timeoutMs: int(env.CONTROL_API_GENERATE_BRIDGE_TIMEOUT_MS, 300000),
    },

    // --- Throttling for state-changing + config-writing endpoints ---------
    rateLimit: {
      windowMs: int(env.CONTROL_API_RATE_WINDOW_MS, 60000),
      max: int(env.CONTROL_API_RATE_MAX, 20),
    },
    // Read endpoints (incl. the live Monitoring/Growth feeds) need only a valid
    // token; a GENEROUS per-identity window keeps polling smooth while still
    // capping abuse. Separate bucket so it never starves the write limit.
    readRateLimit: {
      windowMs: int(env.CONTROL_API_READ_RATE_WINDOW_MS, 60000),
      max: int(env.CONTROL_API_READ_RATE_MAX, 300),
    },

    // Tiny bounded in-memory cache for the READ-ONLY feeds (Monitoring/Growth). The
    // panel polls these every few seconds from several widgets/tabs; this coalesces
    // repeated reads within a short TTL into ONE host (SSH) call. Caches only non-secret,
    // host-global read RESULTS (never writes, never per-identity). Set the TTL to 0 to
    // disable entirely. The size bound keeps memory flat regardless of traffic.
    readCache: {
      ttlMs: intZeroOk(env.CONTROL_API_READ_CACHE_TTL_MS, 2000),
      maxEntries: int(env.CONTROL_API_READ_CACHE_MAX, 64),
    },

    // --- Privacy-first web analytics (Umami) — server-side, read-only ------
    // Optional: when ALL of these are set, GET /api/growth/analytics returns a
    // cookie-less summary fetched from the self-hosted Umami over the INTERNAL
    // network. Credentials stay here and are NEVER returned to the browser. When
    // unset, the endpoint reports a clean "not configured" state.
    analytics: {
      umamiUrl: str(env.CONTROL_API_ANALYTICS_UMAMI_URL),
      username: str(env.CONTROL_API_ANALYTICS_UMAMI_USERNAME),
      password: str(env.CONTROL_API_ANALYTICS_UMAMI_PASSWORD),
      websiteId: str(env.CONTROL_API_ANALYTICS_WEBSITE_ID),
      timeoutMs: int(env.CONTROL_API_ANALYTICS_TIMEOUT_MS, 8000),
    },
  };
}

// True only when the OIDC trust anchors needed to verify a token are present.
export function isAuthConfigured(config) {
  return !!(config.issuer && config.jwksUri && config.audience);
}

function str(v) { return typeof v === 'string' ? v.trim() : ''; }
function int(v, dflt) {
  const n = Number.parseInt(String(v ?? '').trim(), 10);
  return Number.isFinite(n) && n > 0 ? n : dflt;
}
// Like int() but allows an explicit 0 (used where 0 means "disabled"); negatives -> dflt.
function intZeroOk(v, dflt) {
  const n = Number.parseInt(String(v ?? '').trim(), 10);
  return Number.isFinite(n) && n >= 0 ? n : dflt;
}
