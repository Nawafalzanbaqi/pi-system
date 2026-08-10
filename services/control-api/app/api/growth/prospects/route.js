// GET /api/growth/prospects — the prospect organizer board + each prospect's
// embedded last-analysis report, from the prospects store. READ-ONLY (bot-exec
// `prospects_list` -> scripts/panel-read.sh). Any valid token; lightly throttled.
//
// READ/ORGANIZE ONLY: the panel never scrapes, never sends outreach, and (this
// part) never edits prospects — adding/updating a prospect would be a SEPARATE,
// operator-only, audited write action (a possible later part), mirroring
// create-project. The legal/ethical boundary (manual contact only) stays.
import { authorize } from '../../../../lib/authorize.js';
import { executeAction } from '../../../../lib/actions.js';
import { consume } from '../../../../lib/ratelimit.js';
import { tooMany, serverError } from '../../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(request) {
  const auth = await authorize(request, { requireOperator: false });
  if (auth.response) return auth.response;
  const config = auth.config;
  const rl = consume(`read:${auth.identity}`, config.readRateLimit);
  if (!rl.allowed) return tooMany('rate limit exceeded', rl.retryAfterSec);
  try {
    return await executeAction({ action: 'growth-prospects', identity: auth.identity, config, maxOutput: 1048576 });
  } catch {
    return serverError();
  }
}
