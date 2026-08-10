// GET /api/growth/analytics — privacy-first web-analytics summary fetched
// server-side from the self-hosted Umami over the INTERNAL network. Credentials
// live ONLY in this server's env and are NEVER returned to the browser; the
// client receives only the aggregated, cookie-less numbers. When analytics is
// not configured this returns a clean { configured:false } marker (not an error).
// READ-ONLY (no host shell, no bridge — a read GET to Umami's own API). Any valid
// token; lightly throttled.
import { authorize } from '../../../../lib/authorize.js';
import { consume } from '../../../../lib/ratelimit.js';
import { ok, tooMany, serverError } from '../../../../lib/http.js';
import { fetchUmamiSummary } from '../../../../lib/umami.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(request) {
  const auth = await authorize(request, { requireOperator: false });
  if (auth.response) return auth.response;
  const config = auth.config;
  const rl = consume(`read:${auth.identity}`, config.readRateLimit);
  if (!rl.allowed) return tooMany('rate limit exceeded', rl.retryAfterSec);
  try {
    // Returns { configured:false } | { configured:true, ok:false, error } |
    // { configured:true, ok:true, raw:{…} }. Never throws secrets to the client.
    return ok(await fetchUmamiSummary(config));
  } catch {
    return serverError();
  }
}
