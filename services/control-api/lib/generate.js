// ===========================================================================
// pi-system Control API — project GENERATION orchestration (validate -> bridge -> audit)
// ---------------------------------------------------------------------------
// The path behind POST /api/projects. Like lib/actions.js it NEVER builds a shell
// command: it asks buildGenerateArgs for a validated ARGV, runs it through the
// constrained generation bridge (SSH forced-command -> bot-exec-generate.sh ->
// new-project.sh), audits the creation (identity + name + result, never a value),
// and returns a clean JSON envelope with the right status code:
//   * field validation fails        -> 400
//   * a project with that name exists -> 409 (NOTHING was written; no --force)
//   * the host generation errored    -> 502 (with truncated output)
//   * success                        -> 200 (created name + composed details)
// A dry-run (?dryRun=1) validates at THIS layer and returns the would-be plan
// without touching the host — useful for the wizard's review step.
// ===========================================================================
import { buildGenerateArgs } from './generate-core.js';
import { runGenerateBridge } from './bridge.js';
import { ok, fail, serverError } from './http.js';
import { auditRecord, appendAudit } from './audit.js';

// bot-exec-generate.sh exits 3 specifically when the target name already exists
// (a conflict; nothing written). Keep this in sync with that script.
export const GENERATE_CONFLICT_RC = 3;

export async function executeGenerate({ payload, identity, config, dryRun = false, deps = {} }) {
  const built = buildGenerateArgs(payload);
  if (!built.ok) return fail(built.status, built.error);

  const n = built.normalized;

  // Dry-run: validated at the API layer; return WHAT WOULD be created. No host call.
  if (dryRun) {
    return ok({
      dryRun: true,
      name: n.name, preset: n.preset, base: n.base, db: n.db,
      subdomain: n.subdomain, locale: n.locale, modules: n.modules,
    });
  }

  const run = deps.run || runGenerateBridge;
  let result;
  try {
    result = await run(built.argv, config);
  } catch (e) {
    appendAudit(config.auditLog, auditRecord({
      identity, action: 'create-project', target: n.name,
      klass: 'state-changing', result: 'ERROR:bridge-unavailable',
    }), { maxLines: config.auditMaxLines });
    return serverError('host generation bridge unavailable');
  }

  appendAudit(config.auditLog, auditRecord({
    identity, action: 'create-project', target: n.name,
    klass: 'state-changing', result: `EXIT:${result.rc}`,
  }), { maxLines: config.auditMaxLines });

  if (result.rc === GENERATE_CONFLICT_RC) {
    return fail(409, 'a project with that name already exists', { name: n.name });
  }
  if (result.rc !== 0) {
    return fail(502, 'host generation reported a non-zero exit', {
      exitCode: result.rc,
      output: truncate(result.stdout || result.stderr),
    });
  }
  return ok({
    created: n.name, preset: n.preset, base: n.base, db: n.db,
    subdomain: n.subdomain, locale: n.locale, modules: n.modules,
    output: truncate(result.stdout),
  });
}

function truncate(s, max = 16000) {
  const str = String(s || '');
  return str.length > max ? str.slice(0, max) + '\n…(truncated)…' : str;
}
