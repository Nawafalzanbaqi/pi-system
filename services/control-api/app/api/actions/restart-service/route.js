// POST /api/actions/restart-service — OPERATOR-ONLY. Safely restart ONE platform
// service after a config change, via the bot-exec `restart` action which is
// whitelisted to a known service list (scripts/lib/bot-lib.sh BOT_VALID_SERVICE)
// and runs the service's own up/down helper on the host. No arbitrary names, no
// Docker socket. Throttled and audited.
//   body: { "service": "automation|analytics|auth|dashboard|cache|control-api" }
import { authorize } from '../../../../lib/authorize.js';
import { executeAction } from '../../../../lib/actions.js';
import { consume } from '../../../../lib/ratelimit.js';
import { fail, tooMany, serverError } from '../../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function POST(request, context) {
  const auth = await authorize(request, { requireOperator: true });
  if (auth.response) return auth.response;
  const config = auth.config;

  const rl = consume(`restart:${auth.identity}`, config.rateLimit);
  if (!rl.allowed) return tooMany('rate limit exceeded', rl.retryAfterSec);

  let body;
  try { body = await request.json(); } catch { return fail(400, 'request body must be JSON'); }
  const service = body && typeof body.service === 'string' ? body.service : undefined;
  if (!service) return fail(400, 'body must be { "service": "<name>" }');

  try {
    // buildBridgeArgs validates `service` against the restart allowlist; an
    // unknown name is rejected with 400 before anything touches the host.
    return await executeAction({ action: 'restart-service', arg: service, identity: auth.identity, config });
  } catch {
    return serverError();
  }
}
