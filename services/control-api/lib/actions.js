// ===========================================================================
// pi-system Control API — control-action orchestration (validate -> bridge -> audit)
// ---------------------------------------------------------------------------
// The shared path behind both the read-only monitoring endpoints and the
// state-changing POST actions. It NEVER builds a shell command: it asks
// buildBridgeArgs for a validated ARGV, runs it through the constrained bridge
// (SSH forced-command), audits state-changing calls (identity + action + result,
// never a value), and returns a clean JSON envelope with the right status code.
// ===========================================================================
import { buildBridgeArgs } from './bridge-core.js';
import { runBridge } from './bridge.js';
import { ok, fail, serverError } from './http.js';
import { auditRecord, appendAudit } from './audit.js';
import { readCacheGet, readCacheSet } from './cache.js';

// Run the constrained bridge, but for READ-ONLY actions serve from (and populate) the
// tiny bounded TTL cache so repeated polls coalesce into one host call. State-changing
// actions are NEVER cached, and only a SUCCESSFUL read (rc===0) is stored — a transient
// host hiccup must not be cached. `run` is injectable so tests drive it without SSH.
async function runMaybeCached(built, config, run) {
  if (built.class !== 'readonly') return run(built.argv, config);
  const ttlMs = config.readCache ? config.readCache.ttlMs : 0;
  if (!ttlMs) return run(built.argv, config);
  const key = built.argv.join(' ');
  const hit = readCacheGet(key);
  if (hit.hit) return hit.value;
  const result = await run(built.argv, config);
  if (result && result.rc === 0) readCacheSet(key, result, config.readCache);
  return result;
}

export async function executeAction({ action, arg, identity, config, maxOutput = 16000, deps = {} }) {
  const built = buildBridgeArgs(action, arg);
  if (!built.ok) return fail(built.status, built.error);

  const run = deps.runBridge || runBridge;
  const isStateChanging = built.class === 'state-changing';
  const target = built.argv.length > 1 ? built.argv[1] : '-';

  let result;
  try {
    result = await runMaybeCached(built, config, run);
  } catch (e) {
    if (isStateChanging) {
      appendAudit(config.auditLog, auditRecord({
        identity, action, target, klass: built.class, result: 'ERROR:bridge-unavailable',
      }), { maxLines: config.auditMaxLines });
    }
    return serverError('host bridge unavailable');
  }

  if (isStateChanging) {
    appendAudit(config.auditLog, auditRecord({
      identity, action, target, klass: built.class, result: `EXIT:${result.rc}`,
    }), { maxLines: config.auditMaxLines });
  }

  if (result.rc !== 0) {
    return fail(502, 'host action reported a non-zero exit', {
      action,
      exitCode: result.rc,
      output: truncate(result.stdout || result.stderr),
    });
  }
  return ok({ action, exitCode: 0, output: truncate(result.stdout, maxOutput) });
}

function truncate(s, max = 16000) {
  const str = String(s || '');
  return str.length > max ? str.slice(0, max) + '\n…(truncated)…' : str;
}
