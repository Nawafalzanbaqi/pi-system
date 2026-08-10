// GET /api/growth/seo — per-site SEO audit scores over time + rule-based
// recommendations, from the SEO engine's own JSONL store. READ-ONLY (bot-exec
// `seo_audits` -> scripts/panel-read.sh). Any valid token; lightly throttled.
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
    return await executeAction({ action: 'growth-seo', identity: auth.identity, config, maxOutput: 1048576 });
  } catch {
    return serverError();
  }
}
