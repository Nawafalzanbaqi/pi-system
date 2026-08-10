// GET /api/backup-status — last backup + last restore-drill from the backup
// service's own status files. READ-ONLY (bot-exec `backup_status` ->
// scripts/panel-read.sh). Any valid token; lightly throttled.
import { authorize } from '../../../lib/authorize.js';
import { executeAction } from '../../../lib/actions.js';
import { consume } from '../../../lib/ratelimit.js';
import { tooMany, serverError } from '../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(request) {
  const auth = await authorize(request, { requireOperator: false });
  if (auth.response) return auth.response;
  const config = auth.config;
  const rl = consume(`read:${auth.identity}`, config.readRateLimit);
  if (!rl.allowed) return tooMany('rate limit exceeded', rl.retryAfterSec);
  try {
    return await executeAction({ action: 'backup-status', identity: auth.identity, config, maxOutput: 512000 });
  } catch {
    return serverError();
  }
}
