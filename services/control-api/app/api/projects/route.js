// /api/projects
//   GET  — list generated projects + their state via the bot-exec `projects`
//          action. Read-only; requires a valid token.
//   POST — OPERATOR-ONLY. Securely SCAFFOLD a new project: validates the wizard
//          payload at the API layer (defence in depth — bot-exec-generate.sh
//          re-validates every field on the host), then maps it to an ARGV array
//          run through the constrained generation bridge (no Docker socket, no
//          shell, no --force). Returns 200 (created), 400 (validation),
//          409 (name already exists), 403 (not operator) or 502 (host error).
//          `?dryRun=1` validates and returns what WOULD be created without writing.
//          Generation creates the project FILES only; bringing it up/deploying is
//          a SEPARATE action (POST /api/actions/project-up).
import { authorize } from '../../../lib/authorize.js';
import { executeAction } from '../../../lib/actions.js';
import { executeGenerate } from '../../../lib/generate.js';
import { consume } from '../../../lib/ratelimit.js';
import { fail, tooMany, serverError } from '../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(request) {
  const auth = await authorize(request, { requireOperator: false });
  if (auth.response) return auth.response;
  try {
    return await executeAction({ action: 'projects', identity: auth.identity, config: auth.config });
  } catch {
    return serverError();
  }
}

export async function POST(request) {
  const auth = await authorize(request, { requireOperator: true });
  if (auth.response) return auth.response;
  const config = auth.config;

  const rl = consume(`generate:${auth.identity}`, config.rateLimit);
  if (!rl.allowed) return tooMany('rate limit exceeded', rl.retryAfterSec);

  let body;
  try { body = await request.json(); } catch { return fail(400, 'request body must be JSON'); }
  if (body == null || typeof body !== 'object') return fail(400, 'request body must be a JSON object');

  // dryRun via query string (?dryRun=1) or an explicit body flag.
  let dryRun = body.dryRun === true;
  try { dryRun = dryRun || new URL(request.url).searchParams.get('dryRun') === '1'; } catch { /* ignore */ }

  try {
    return await executeGenerate({ payload: body, identity: auth.identity, config, dryRun });
  } catch {
    return serverError();
  }
}
