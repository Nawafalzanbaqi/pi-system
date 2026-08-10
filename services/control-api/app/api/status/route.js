// GET /api/status — whole-system snapshot via the existing bot-exec `status`
// action (which orchestrates scripts/pi status). Read-only; requires a valid token.
import { authorize } from '../../../lib/authorize.js';
import { executeAction } from '../../../lib/actions.js';
import { serverError } from '../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(request) {
  const auth = await authorize(request, { requireOperator: false });
  if (auth.response) return auth.response;
  try {
    return await executeAction({ action: 'status', identity: auth.identity, config: auth.config });
  } catch {
    return serverError();
  }
}
