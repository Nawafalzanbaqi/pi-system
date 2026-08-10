// GET /api/checks — read-only readiness gates via the existing bot-exec `check`
// action (scripts/pi check = preflight + mem-budget). Requires a valid token.
import { authorize } from '../../../lib/authorize.js';
import { executeAction } from '../../../lib/actions.js';
import { serverError } from '../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(request) {
  const auth = await authorize(request, { requireOperator: false });
  if (auth.response) return auth.response;
  try {
    return await executeAction({ action: 'checks', identity: auth.identity, config: auth.config });
  } catch {
    return serverError();
  }
}
