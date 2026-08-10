// GET /api/integrations — per-integration view of every allowlisted config key:
// label, SET vs EMPTY, and for SECRETS a masked indicator ONLY. Secret VALUES are
// NEVER returned. Read requires a valid token (any authenticated user may view
// the configuration map; only operators may change it via PUT).
import { readFileSync } from 'node:fs';

import { authorize } from '../../../lib/authorize.js';
import { loadRegistry, describeKey } from '../../../lib/registry.js';
import { summarizeIntegrations } from '../../../lib/env.js';
import { ok, serverError } from '../../../lib/http.js';

export const dynamic = 'force-dynamic';
export const runtime = 'nodejs';

export async function GET(request) {
  const auth = await authorize(request, { requireOperator: false });
  if (auth.response) return auth.response;
  try {
    const reg = loadRegistry();
    let envText = '';
    try { envText = readFileSync(auth.config.envFile, 'utf8'); } catch { envText = ''; }
    const integrations = summarizeIntegrations(reg, envText, describeKey);
    return ok({ integrations });
  } catch {
    return serverError();
  }
}
