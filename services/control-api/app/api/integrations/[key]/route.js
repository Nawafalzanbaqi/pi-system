// PUT /api/integrations/{key} — OPERATOR-ONLY. Set one allowlisted config key:
//   * the key MUST be in the registry allowlist (env-writer enforces this),
//   * the value MUST pass the key's basic shape check (and may never contain a
//     newline — line-injection guard),
//   * .env is backed up first, then written atomically with structure preserved,
//   * the VALUE is NEVER logged; the audit records only key + identity + result,
//   * the response says which services now need a RESTART.
// Throttled (state-changing / config-writing).
import { authorize } from '../../../../lib/authorize.js';
import { loadRegistry } from '../../../../lib/registry.js';
import { writeEnvKey } from '../../../../lib/env-writer.js';
import { consume } from '../../../../lib/ratelimit.js';
import { auditRecord, appendAudit } from '../../../../lib/audit.js';
import { ok, fail, tooMany, serverError } from '../../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function PUT(request, context) {
  const auth = await authorize(request, { requireOperator: true });
  if (auth.response) return auth.response;
  const config = auth.config;

  // Throttle per identity.
  const rl = consume(`put:${auth.identity}`, config.rateLimit);
  if (!rl.allowed) return tooMany('rate limit exceeded', rl.retryAfterSec);

  const params = await context.params;          // Next 15: params is async
  const key = params?.key;

  // Parse body: { value: "<string>" }.
  let body;
  try { body = await request.json(); } catch { return fail(400, 'request body must be JSON'); }
  if (!body || typeof body.value !== 'string') {
    return fail(400, 'body must be { "value": "<string>" }');
  }

  try {
    const reg = loadRegistry();
    const res = writeEnvKey({
      reg,
      key,
      value: body.value,
      envFile: config.envFile,
      backupDir: config.backupDir,
    });

    if (!res.ok) {
      // Audit the REJECTED attempt (key name only — never the value).
      appendAudit(config.auditLog, auditRecord({
        identity: auth.identity, action: 'config-set', target: safeKey(key),
        klass: 'config-write', result: `REJECTED:${res.status}`,
      }), { maxLines: config.auditMaxLines });
      return fail(res.status, res.error);
    }

    // Audit the successful write — key + identity + result, NEVER the value.
    appendAudit(config.auditLog, auditRecord({
      identity: auth.identity, action: 'config-set', target: res.key,
      klass: 'config-write', result: 'OK',
    }), { maxLines: config.auditMaxLines });

    return ok({
      key: res.key,
      updated: true,
      restart_services: res.restart_services,
    });
  } catch {
    return serverError();
  }
}

function safeKey(k) {
  return typeof k === 'string' && /^[A-Za-z0-9_]+$/.test(k) ? k : '(invalid)';
}
