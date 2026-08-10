// GET /api/monitoring — LIVE host metrics for the Monitoring view (time-series
// from health-monitor's health.log + latest verdict from last-health.json +
// a current per-container memory snapshot). READ-ONLY: maps to the bot-exec
// `monitor_metrics` action -> scripts/panel-read.sh (cats/tails the producer's
// files; no mutation, no Docker socket). Any valid token; lightly throttled.
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
    return await executeAction({ action: 'monitoring', identity: auth.identity, config, maxOutput: 512000 });
  } catch {
    return serverError();
  }
}
