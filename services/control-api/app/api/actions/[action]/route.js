// POST /api/actions/{up|down|project-up|project-down} — OPERATOR-ONLY.
// Maps to the SAME fixed bot-exec action set (no arbitrary host commands, no
// Docker socket). Strictly validated, throttled and audited (identity, action,
// result). `restart-service` is a SEPARATE route (a static segment that takes
// precedence over this dynamic one).
//   up   / down          body: { "profile": "core|dev|auth|automation" }  (default core)
//   project-up / -down   body: { "project": "<generated-project-name>" }
import { authorize } from '../../../../lib/authorize.js';
import { executeAction } from '../../../../lib/actions.js';
import { consume } from '../../../../lib/ratelimit.js';
import { fail, tooMany, serverError } from '../../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

// Only these state-changing actions are reachable through this POST route.
const ALLOWED = new Set(['up', 'down', 'project-up', 'project-down']);

export async function POST(request, context) {
  const auth = await authorize(request, { requireOperator: true });
  if (auth.response) return auth.response;
  const config = auth.config;

  const params = await context.params;
  const action = params?.action;
  if (!ALLOWED.has(action)) return fail(404, 'unknown action');

  const rl = consume(`action:${auth.identity}`, config.rateLimit);
  if (!rl.allowed) return tooMany('rate limit exceeded', rl.retryAfterSec);

  // Body is optional for up/down (profile defaults to core).
  let body = {};
  if (request.headers.get('content-length') && request.headers.get('content-length') !== '0') {
    try { body = await request.json(); } catch { return fail(400, 'request body must be JSON'); }
  }

  let arg;
  if (action === 'up' || action === 'down') {
    arg = typeof body.profile === 'string' ? body.profile : undefined;
  } else {
    arg = typeof body.project === 'string' ? body.project : undefined;
  }

  try {
    return await executeAction({ action, arg, identity: auth.identity, config });
  } catch {
    return serverError();
  }
}
