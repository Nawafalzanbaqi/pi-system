// ===========================================================================
// pi-system Control API — PURE-LOGIC test driver (raw node, no Docker/net/jose)
// ---------------------------------------------------------------------------
// Imports ONLY the dependency-free lib modules (never authorize.js/verify-token.js
// which pull in jose) and proves the security-critical behaviour:
//   * AUTHZ matrix          no payload->401, non-operator->403, operator->allowed
//   * REGISTRY allowlist    only manifest keys are editable; shape validation
//   * SECRETS never returned describeKey/summarizeIntegrations expose no values
//   * SAFE .env WRITER      structure preserved, backup made, no value leaked (mock fs)
//   * RESTART whitelist     buildBridgeArgs + isAllowedRestartService
//   * NO ARBITRARY SHELL    argv is always an array; assertSafeArgv rejects metachars
//   * RATE LIMIT / CONFIG / AUDIT
// Exits non-zero on the first category that fails (run.sh aggregates).
// ===========================================================================
import * as path from 'node:path';

import {
  loadRegistry, isAllowedKey, getKeyDef, validateValue, describeKey, restartServicesForKey,
} from '../../services/control-api/lib/registry.js';
import {
  parseEnvText, getEnvValue, setEnvValue, summarizeIntegrations,
} from '../../services/control-api/lib/env.js';
import { writeEnvKey } from '../../services/control-api/lib/env-writer.js';
import {
  extractBearer, evaluateAuth, hasOperatorRole, rolesOf, identityOf,
} from '../../services/control-api/lib/auth-core.js';
import {
  buildBridgeArgs, isAllowedRestartService, isValidProfile, VALID_RESTART_SERVICES, ACTION_MAP,
} from '../../services/control-api/lib/bridge-core.js';
import { assertSafeArgv, assertSafeGenerateArgv } from '../../services/control-api/lib/bridge.js';
import { checkRate } from '../../services/control-api/lib/ratelimit.js';
import {
  auditRecord, auditLine, trimToLastLines, appendAudit, trimAuditLog, DEFAULT_AUDIT_MAX_LINES,
} from '../../services/control-api/lib/audit.js';
import { getConfig, isAuthConfigured } from '../../services/control-api/lib/config.js';
import { executeAction } from '../../services/control-api/lib/actions.js';
import {
  buildGenerateArgs, isValidProjectName as gIsValidName, isValidSubdomain as gIsValidSub,
  VALID_PRESETS as G_PRESETS, VALID_BASES as G_BASES, VALID_DBS as G_DBS,
  VALID_LOCALES as G_LOCALES, VALID_MODULES as G_MODULES,
} from '../../services/control-api/lib/generate-core.js';
import { executeGenerate, GENERATE_CONFLICT_RC } from '../../services/control-api/lib/generate.js';
import { isReadonlyAction, READONLY_ACTIONS } from '../../services/control-api/lib/bridge-core.js';
import { isAnalyticsConfigured, fetchUmamiSummary } from '../../services/control-api/lib/umami.js';
import { cacheGet, cacheSet, readCacheClear } from '../../services/control-api/lib/cache.js';
import * as os from 'node:os';

// --- tiny harness ----------------------------------------------------------
let run = 0, failed = 0;
const G = process.stdout.isTTY ? '\x1b[0;32m' : '';
const R = process.stdout.isTTY ? '\x1b[0;31m' : '';
const C = process.stdout.isTTY ? '\x1b[1;36m' : '';
const O = process.stdout.isTTY ? '\x1b[0m' : '';
function section(s) { console.log(`\n${C}== ${s} ==${O}`); }
function ok(name, cond) {
  run++;
  if (cond) console.log(`  ${G}✓${O} ${name}`);
  else { failed++; console.log(`  ${R}✗${O} ${name}`); }
}
function eq(name, a, b) { ok(`${name} (got ${JSON.stringify(a)})`, a === b); }

// --- in-memory fs for the writer ------------------------------------------
function memFs(initial = {}) {
  const files = new Map(Object.entries(initial));
  const calls = { writes: [], renames: [], mkdirs: [], appends: [] };
  return {
    files, calls,
    existsSync: (p) => files.has(p),
    readFileSync: (p) => {
      if (!files.has(p)) { const e = new Error('ENOENT'); e.code = 'ENOENT'; throw e; }
      return files.get(p);
    },
    writeFileSync: (p, data) => { files.set(p, String(data)); calls.writes.push(p); },
    renameSync: (a, b) => {
      if (!files.has(a)) { const e = new Error('ENOENT'); e.code = 'ENOENT'; throw e; }
      files.set(b, files.get(a)); files.delete(a); calls.renames.push([a, b]);
    },
    mkdirSync: (p) => { calls.mkdirs.push(p); },
    unlinkSync: (p) => { files.delete(p); },
    appendFileSync: (p, data) => { files.set(p, (files.get(p) || '') + String(data)); calls.appends.push(p); },
  };
}

const reg = loadRegistry();

// ===========================================================================
section('AUTHZ — pure decision (no token -> 401, non-operator -> 403, operator -> ok)');
// ---------------------------------------------------------------------------
eq('bearer extracted', extractBearer('Bearer abc.def.ghi'), 'abc.def.ghi');
eq('bearer case-insensitive', extractBearer('bearer xyz'), 'xyz');
eq('no header -> null', extractBearer(undefined), null);
eq('malformed header -> null', extractBearer('Token abc'), null);

const opCfg = { operatorRole: 'operator', audience: 'control-panel' };
const operator = { sub: 'u1', preferred_username: 'nawaf', realm_access: { roles: ['operator', 'user'] } };
const viewer = { sub: 'u2', preferred_username: 'bob', realm_access: { roles: ['user'] } };
const clientOp = { sub: 'u3', resource_access: { 'control-panel': { roles: ['operator'] } } };

eq('no payload -> 401', evaluateAuth({ payload: null, config: opCfg, requireOperator: false }).status, 401);
eq('viewer read allowed -> 200', evaluateAuth({ payload: viewer, config: opCfg, requireOperator: false }).status, 200);
eq('viewer write -> 403', evaluateAuth({ payload: viewer, config: opCfg, requireOperator: true }).status, 403);
eq('operator write -> 200', evaluateAuth({ payload: operator, config: opCfg, requireOperator: true }).status, 200);
ok('operator role (realm)', hasOperatorRole(operator, opCfg));
ok('operator role (client/resource_access)', hasOperatorRole(clientOp, opCfg));
ok('viewer is NOT operator', !hasOperatorRole(viewer, opCfg));
ok('roles collected', rolesOf(operator, opCfg).has('operator'));
eq('identity label', identityOf(operator), 'nawaf');
eq('anon identity', identityOf(null), 'anonymous');

// ===========================================================================
section('REGISTRY — allowlist + value shape validation');
// ---------------------------------------------------------------------------
ok('TELEGRAM_BOT_TOKEN is editable', isAllowedKey(reg, 'TELEGRAM_BOT_TOKEN'));
ok('AI_API_KEY is editable', isAllowedKey(reg, 'AI_API_KEY'));
ok('PAYMENTS_API_KEY is editable', isAllowedKey(reg, 'PAYMENTS_API_KEY'));
ok('unknown key rejected', !isAllowedKey(reg, 'TOTALLY_MADE_UP'));
// CRITICAL: a real .env secret that is NOT in the manifest must be untouchable.
ok('REDIS_PASSWORD NOT editable (not in manifest)', !isAllowedKey(reg, 'REDIS_PASSWORD'));
ok('KC_DB_PASSWORD NOT editable (not in manifest)', !isAllowedKey(reg, 'KC_DB_PASSWORD'));
ok('PATH NOT editable', !isAllowedKey(reg, 'PATH'));

// shape checks (each gives a testable rejection)
const tgIds = getKeyDef(reg, 'TELEGRAM_ALLOWED_IDS');
ok('digits_csv accepts "111,222"', validateValue(tgIds, '111,222').ok);
ok('digits_csv rejects "abc"', !validateValue(tgIds, 'abc').ok);
const prov = getKeyDef(reg, 'AI_PROVIDER');
ok('enum accepts "openai"', validateValue(prov, 'openai').ok);
ok('enum rejects "foo"', !validateValue(prov, 'foo').ok);
const url = getKeyDef(reg, 'AI_BASE_URL');
ok('url accepts https', validateValue(url, 'https://api.example.com').ok);
ok('url rejects "nope"', !validateValue(url, 'nope').ok);
const tok = getKeyDef(reg, 'AI_API_KEY');
ok('token accepts "sk-abc123"', validateValue(tok, 'sk-abc123').ok);
// UNIVERSAL line-injection guard: no value may contain a newline.
ok('newline rejected (line injection)', !validateValue(tok, 'sk\nINJECTED=evil').ok);
ok('carriage-return rejected', !validateValue(tok, 'sk\rEVIL').ok);
// empty handling
const appSecret = getKeyDef(reg, 'ANALYTICS_APP_SECRET');
ok('non-empty-required key rejects ""', !validateValue(appSecret, '').ok);
ok('allow_empty key accepts "" (clear)', validateValue(tgIds, '').ok);
// restart_services come from the manifest
eq('telegram token restarts automation', restartServicesForKey(reg, 'TELEGRAM_BOT_TOKEN').join(','), 'automation');
eq('AI key restarts nothing', restartServicesForKey(reg, 'AI_API_KEY').join(','), '');

// ===========================================================================
section('SECRETS — values are NEVER returned (masked / set / empty only)');
// ---------------------------------------------------------------------------
const SECRET_VAL = 'super-secret-token-DO-NOT-LEAK';
const d1 = describeKey(getKeyDef(reg, 'TELEGRAM_BOT_TOKEN'), SECRET_VAL);
ok('secret describe has no `value` field', !('value' in d1));
ok('secret describe marks set', d1.set === true && d1.secret === true);
ok('secret describe masked, not the value', d1.masked && d1.masked !== SECRET_VAL);
const d2 = describeKey(getKeyDef(reg, 'TELEGRAM_ALLOWED_IDS'), '111,222');
ok('non-secret describe DOES include value', d2.value === '111,222' && d2.secret === false);

const sampleEnv = [
  '# comment', 'BASE_DOMAIN=example.com',
  `TELEGRAM_BOT_TOKEN=${SECRET_VAL}`,
  'TELEGRAM_ALLOWED_IDS=111,222',
  'AI_API_KEY=ai-secret-value-xyz',
  'REDIS_PASSWORD=some-redis-password',
].join('\n') + '\n';
const summary = summarizeIntegrations(reg, sampleEnv, describeKey);
const summaryJson = JSON.stringify(summary);
ok('summary NEVER contains the bot token value', !summaryJson.includes(SECRET_VAL));
ok('summary NEVER contains the AI key value', !summaryJson.includes('ai-secret-value-xyz'));
ok('summary NEVER leaks an unrelated .env secret', !summaryJson.includes('some-redis-password'));
ok('summary marks the bot token as set', summary.find((i) => i.id === 'telegram').keys.find((k) => k.key === 'TELEGRAM_BOT_TOKEN').set === true);

// ===========================================================================
section('ENV WRITER — structure preserved, backup made, value never leaked');
// ---------------------------------------------------------------------------
const ENV = '/work/.env';
const original =
  '# header comment\n' +
  'BASE_DOMAIN=example.com\n' +
  'TELEGRAM_ALLOWED_IDS=\n' +
  '# a comment between\n' +
  'AI_PROVIDER=none\n';

// setEnvValue (pure) — in place, preserves everything else.
const updatedText = setEnvValue(original, 'AI_PROVIDER', 'openai');
ok('setEnvValue updates the target line', getEnvValue(updatedText, 'AI_PROVIDER') === 'openai');
ok('setEnvValue keeps the header comment', updatedText.includes('# header comment'));
ok('setEnvValue keeps the in-between comment', updatedText.includes('# a comment between'));
ok('setEnvValue keeps unrelated keys', getEnvValue(updatedText, 'BASE_DOMAIN') === 'example.com');
ok('setEnvValue appends a missing key', getEnvValue(setEnvValue(original, 'AI_MODEL', 'gpt'), 'AI_MODEL') === 'gpt');
ok('parseEnv ignores comments/blanks', !parseEnvText('# x\n\nFOO=bar').has('#'));

// writeEnvKey (fs seam, mocked) — full safe write.
const fs1 = memFs({ [ENV]: original });
const res = writeEnvKey({
  reg, key: 'AI_PROVIDER', value: 'openai', envFile: ENV,
  deps: { fs: fs1, path }, now: () => new Date('2026-05-23T10:20:30Z'),
});
ok('write succeeds', res.ok === true);
ok('write result has NO value field', !('value' in res));
ok('.env now has the new value', getEnvValue(fs1.files.get(ENV), 'AI_PROVIDER') === 'openai');
ok('.env structure preserved (comment kept)', fs1.files.get(ENV).includes('# header comment'));
const backupName = res.backup;
ok('a timestamped backup was created', !!fs1.files.get(backupName) && /\.env\.bak\./.test(backupName));
ok('backup holds the ORIGINAL content', fs1.files.get(backupName) === original);
ok('atomic rename was used', fs1.calls.renames.length === 1);

// writeEnvKey rejects a key NOT in the allowlist — WITHOUT touching the fs.
const fs2 = memFs({ [ENV]: original });
const bad = writeEnvKey({ reg, key: 'REDIS_PASSWORD', value: 'x', envFile: ENV, deps: { fs: fs2, path } });
ok('non-allowlisted key rejected', bad.ok === false && bad.status === 400);
ok('rejected write touched NO file', fs2.calls.writes.length === 0 && fs2.calls.renames.length === 0);

// writeEnvKey rejects a newline value (line-injection) — no write.
const fs3 = memFs({ [ENV]: original });
const inj = writeEnvKey({ reg, key: 'AI_MODEL', value: 'a\nMALICIOUS=1', envFile: ENV, deps: { fs: fs3, path } });
ok('newline value rejected', inj.ok === false && inj.status === 400);
ok('rejected injection touched NO file', fs3.calls.writes.length === 0);

// ===========================================================================
section('AUDIT — record carries key/identity/result but NEVER a value');
// ---------------------------------------------------------------------------
const rec = auditRecord({ identity: 'nawaf', action: 'config-set', target: 'AI_API_KEY', klass: 'config-write', result: 'OK' });
const recJson = auditLine(rec);
ok('audit has the key name', recJson.includes('AI_API_KEY'));
ok('audit has the identity', recJson.includes('nawaf'));
ok('audit record exposes only whitelisted fields', Object.keys(rec).sort().join(',') === 'action,class,identity,result,target,ts');
ok('audit cannot carry a value field', !('value' in rec));

// ===========================================================================
section('AUDIT TRIM — log self-bounds (pure helper + atomic, value-free on-disk trim)');
// ---------------------------------------------------------------------------
// (a) PURE trimToLastLines: keeps the NEWEST lines, preserves a trailing newline,
//     <=0 disables, empty stays empty, and it never mutates its input.
eq('trim: under the limit is unchanged', trimToLastLines('a\nb\nc\n', 5), 'a\nb\nc\n');
eq('trim: exactly N is unchanged', trimToLastLines('a\nb\nc\n', 3), 'a\nb\nc\n');
eq('trim: over limit keeps the newest N (trailing nl)', trimToLastLines('a\nb\nc\nd\ne\n', 3), 'c\nd\ne\n');
eq('trim: over limit keeps the newest N (no trailing nl)', trimToLastLines('a\nb\nc\nd', 2), 'c\nd');
eq('trim: maxLines<=0 disables trimming', trimToLastLines('a\nb\nc\n', 0), 'a\nb\nc\n');
eq('trim: empty input stays empty', trimToLastLines('', 5), '');
{
  const input = 'a\nb\nc\nd\ne\n';
  const once = trimToLastLines(input, 3);
  ok('trim: does NOT mutate its input (pure)', input === 'a\nb\nc\nd\ne\n');
  ok('trim: is idempotent', trimToLastLines(once, 3) === once);
}
eq('DEFAULT_AUDIT_MAX_LINES is the documented 5000', DEFAULT_AUDIT_MAX_LINES, 5000);

// (b) appendAudit on-disk, UNDER the limit: the prior content is untouched — only
//     the new line is appended; no rewrite/rename happens (via the mem-fs seam).
{
  const LOG = '/work/audit.log';
  const seeded = 'old-1\nold-2\nold-3\n';
  const fs = memFs({ [LOG]: seeded });
  const wrote = appendAudit(LOG, auditRecord({ identity: 'op', action: 'config-set', target: 'AI_PROVIDER', result: 'OK' }), { fs, path, maxLines: 5000 });
  const after = fs.files.get(LOG);
  ok('append under limit succeeds', wrote === true);
  ok('append under limit keeps the prior lines verbatim', after.startsWith(seeded));
  ok('append under limit added exactly one line', after.split('\n').filter(Boolean).length === 4);
  ok('append under limit did NOT rewrite/rename', fs.calls.renames.length === 0);
}

// (c) appendAudit on-disk, OVER the limit: trims to EXACTLY N, keeping the newest
//     (incl. the just-appended record), ATOMICALLY (temp file renamed over the log).
{
  const LOG = '/work/audit.log';
  const fs = memFs({ [LOG]: 'old-1\nold-2\nold-3\n' });   // already at the cap of 3
  appendAudit(LOG, auditRecord({ identity: 'newcomer', action: 'restart-service', target: 'analytics', result: 'EXIT:0' }), { fs, path, maxLines: 3 });
  const after = fs.files.get(LOG);
  const lines = after.split('\n').filter(Boolean);
  eq('over limit trims to EXACTLY N lines', lines.length, 3);
  ok('over limit drops the OLDEST line', !after.includes('old-1'));
  ok('over limit keeps the next-oldest survivors', after.includes('old-2') && after.includes('old-3'));
  ok('over limit keeps the NEWEST (just-appended) line', after.includes('newcomer'));
  ok('trim is ATOMIC (temp file renamed over the log)',
    fs.calls.renames.length === 1 && fs.calls.renames[0][0] === `${LOG}.tmp` && fs.calls.renames[0][1] === LOG);
  ok('trim leaves NO temp file behind', !fs.files.has(`${LOG}.tmp`));
}

// (d) maxLines = 0 disables trimming entirely (operator may opt out of the cap).
{
  const LOG = '/work/audit.log';
  const fs = memFs({ [LOG]: 'l1\nl2\nl3\nl4\nl5\n' });
  appendAudit(LOG, auditRecord({ identity: 'op', action: 'status', result: 'EXIT:0' }), { fs, path, maxLines: 0 });
  ok('maxLines=0 never trims (all 6 lines kept)', fs.files.get(LOG).split('\n').filter(Boolean).length === 6);
  ok('maxLines=0 never rewrote the file', fs.calls.renames.length === 0);
}

// (e) trimAuditLog is a no-op (no throw) when the file does not exist yet.
{
  const fs = memFs({});
  ok('trimAuditLog on a missing file is a safe no-op', trimAuditLog('/work/nope.log', 100, { fs }) === false);
}

// ===========================================================================
section('RESTART — whitelisted to known services; bridge args are an ARRAY');
// ---------------------------------------------------------------------------
ok('automation is restartable', isAllowedRestartService('automation'));
ok('control-api is restartable', isAllowedRestartService('control-api'));
ok('postgres is NOT restartable', !isAllowedRestartService('postgres'));
ok('keycloak-db is NOT restartable', !isAllowedRestartService('keycloak-db'));
const rsvc = buildBridgeArgs('restart-service', 'analytics');
ok('restart-service maps to bot-exec restart', rsvc.ok && Array.isArray(rsvc.argv) && rsvc.argv[0] === 'restart' && rsvc.argv[1] === 'analytics');
ok('restart bad service rejected', !buildBridgeArgs('restart-service', 'postgres').ok);
ok('restart missing service rejected', !buildBridgeArgs('restart-service', '').ok);

// ===========================================================================
section('BRIDGE — never builds a shell command (argv array + safe tokens)');
// ---------------------------------------------------------------------------
const up = buildBridgeArgs('up', undefined);
ok('up defaults to core profile', up.ok && up.argv.join(' ') === 'up core');
ok('up argv is an ARRAY (not a string)', Array.isArray(up.argv));
ok('bad profile rejected', !buildBridgeArgs('up', 'bogus').ok);
ok('project-up validates name shape', buildBridgeArgs('project-up', 'acme-portal').ok);
ok('project-up rejects traversal', !buildBridgeArgs('project-up', '../etc').ok);
ok('readonly action takes no arg', !buildBridgeArgs('status', 'x').ok);
ok('unknown action rejected', !buildBridgeArgs('rm-rf', 'x').ok);
// assertSafeArgv is the last line of defence before the transport.
let threw = false; try { assertSafeArgv(['up', 'core; rm -rf /']); } catch { threw = true; }
ok('assertSafeArgv rejects shell metacharacters', threw);
threw = false; try { assertSafeArgv(['up', '$(whoami)']); } catch { threw = true; }
ok('assertSafeArgv rejects command substitution', threw);
ok('assertSafeArgv accepts clean argv', (() => { try { assertSafeArgv(['restart', 'analytics']); return true; } catch { return false; } })());
// executeAction with a bogus action returns a 400 Response WITHOUT touching the host.
const bogusRes = await executeAction({ action: 'bogus', identity: 'x', config: getConfig({}) });
eq('executeAction rejects bogus action (no host call)', bogusRes.status, 400);

// ===========================================================================
section('RATE LIMIT + CONFIG');
// ---------------------------------------------------------------------------
const st = {};
const opts = { windowMs: 1000, max: 2 };
ok('1st allowed', checkRate(st, 'k', 0, opts).allowed);
ok('2nd allowed', checkRate(st, 'k', 10, opts).allowed);
ok('3rd blocked', !checkRate(st, 'k', 20, opts).allowed);
ok('resets after window', checkRate(st, 'k', 1100, opts).allowed);
ok('auth NOT configured when issuer missing', !isAuthConfigured(getConfig({})));
ok('auth configured when issuer+aud set', isAuthConfigured(getConfig({
  CONTROL_API_OIDC_ISSUER: 'https://auth.example.com/realms/pi',
  CONTROL_API_OIDC_AUDIENCE: 'control-panel',
})));
eq('jwks defaults under issuer', getConfig({
  CONTROL_API_OIDC_ISSUER: 'https://auth.example.com/realms/pi',
  CONTROL_API_OIDC_AUDIENCE: 'control-panel',
}).jwksUri, 'https://auth.example.com/realms/pi/protocol/openid-connect/certs');

// ===========================================================================
section('READ-FEED CACHE — bounded TTL cache coalesces repeated read polls');
// ---------------------------------------------------------------------------
// (a) PURE core: miss -> hit-within-ttl -> expiry -> oldest-eviction at the size bound.
{
  const s = new Map();
  ok('cache miss on empty store', cacheGet(s, 'k', 0).hit === false);
  cacheSet(s, 'k', { v: 1 }, 0, { ttlMs: 100, maxEntries: 3 });
  const h = cacheGet(s, 'k', 50);
  ok('cache hit within ttl returns the value', h.hit === true && h.value.v === 1);
  ok('cache miss after the ttl expires', cacheGet(s, 'k', 100).hit === false);
  const s2 = new Map();
  cacheSet(s2, 'a', 1, 0, { ttlMs: 1000, maxEntries: 2 });
  cacheSet(s2, 'b', 2, 0, { ttlMs: 1000, maxEntries: 2 });
  cacheSet(s2, 'c', 3, 0, { ttlMs: 1000, maxEntries: 2 });
  eq('size bound holds', s2.size, 2);
  ok('oldest entry evicted past the cap', cacheGet(s2, 'a', 0).hit === false);
  ok('newer entries kept', cacheGet(s2, 'b', 0).hit && cacheGet(s2, 'c', 0).hit);
}

// (b) executeAction wiring: a READ-ONLY action is served from cache (two identical polls
//     -> ONE host call); a STATE-CHANGING action is NEVER cached; ttl=0 disables it; a
//     FAILED read (rc!=0) is not cached. `deps.runBridge` is the injected host seam.
{
  const auditLog = path.join(os.tmpdir(), `ca-audit-test-${process.pid}.log`);
  const cfg = { ...getConfig({}), readCache: { ttlMs: 2000, maxEntries: 16 }, auditLog };
  let calls = 0;
  const fakeRun = async (argv) => { calls++; return { rc: 0, stdout: `out:${argv.join(',')}:${calls}`, stderr: '' }; };

  readCacheClear(); calls = 0;
  const r1 = await executeAction({ action: 'monitoring', identity: 'op', config: cfg, deps: { runBridge: fakeRun } });
  const r2 = await executeAction({ action: 'monitoring', identity: 'op2', config: cfg, deps: { runBridge: fakeRun } });
  eq('read-only: two polls -> one host call (cached)', calls, 1);
  const b1 = await r1.json(); const b2 = await r2.json();
  ok('read-only: both responses carry the same cached output', b1.data.output === b2.data.output);

  readCacheClear(); calls = 0;
  await executeAction({ action: 'restart-service', arg: 'analytics', identity: 'op', config: cfg, deps: { runBridge: fakeRun } });
  await executeAction({ action: 'restart-service', arg: 'analytics', identity: 'op', config: cfg, deps: { runBridge: fakeRun } });
  eq('state-changing: never cached (two calls -> two host calls)', calls, 2);

  readCacheClear(); calls = 0;
  const cfgOff = { ...cfg, readCache: { ttlMs: 0, maxEntries: 16 } };
  await executeAction({ action: 'monitoring', identity: 'op', config: cfgOff, deps: { runBridge: fakeRun } });
  await executeAction({ action: 'monitoring', identity: 'op', config: cfgOff, deps: { runBridge: fakeRun } });
  eq('ttl=0 disables caching (two polls -> two host calls)', calls, 2);

  readCacheClear(); calls = 0;
  const failRun = async () => { calls++; return { rc: 1, stdout: '', stderr: 'boom' }; };
  await executeAction({ action: 'monitoring', identity: 'op', config: cfg, deps: { runBridge: failRun } });
  await executeAction({ action: 'monitoring', identity: 'op', config: cfg, deps: { runBridge: failRun } });
  eq('failed read (rc!=0) is not cached', calls, 2);
  readCacheClear();
  try { (await import('node:fs')).rmSync(auditLog, { force: true }); } catch { /* best-effort cleanup */ }
}

// ===========================================================================
section('CONSISTENCY — registry restart_services are all in the bridge allowlist');
// ---------------------------------------------------------------------------
let allInAllowlist = true;
for (const integ of reg.integrations) {
  for (const k of integ.keys) {
    for (const s of (k.restart_services || [])) {
      if (!VALID_RESTART_SERVICES.includes(s)) { allInAllowlist = false; console.log(`    offending: ${k.key} -> ${s}`); }
    }
  }
}
ok('every restart_services value is whitelisted', allInAllowlist);
ok('ACTION_MAP exposes restart-service', ACTION_MAP['restart-service'] === 'restart');
ok('profiles include core', isValidProfile('core'));

// ===========================================================================
section('CREATE-PROJECT — field validation -> ARGV (never shell, never --force)');
// ---------------------------------------------------------------------------
// A valid preset payload builds a clean ARGV array; a valid base payload too.
const gOk = buildGenerateArgs({ name: 'noor', preset: 'ecommerce', db: 'postgres', subdomain: 'noor', locale: 'ar', modules: ['i18n-bilingual', 'web-analytics', 'i18n-bilingual'] });
ok('valid preset payload accepted', gOk.ok === true);
ok('generate argv is an ARRAY (not a string)', Array.isArray(gOk.argv));
ok('argv starts with create-project action', gOk.argv[0] === 'create-project');
ok('argv carries --name noor', gOk.argv.includes('--name') && gOk.argv[gOk.argv.indexOf('--name') + 1] === 'noor');
ok('argv carries --preset ecommerce', gOk.argv[gOk.argv.indexOf('--preset') + 1] === 'ecommerce');
ok('argv carries --db postgres', gOk.argv[gOk.argv.indexOf('--db') + 1] === 'postgres');
ok('argv dedupes modules into one CSV token', gOk.argv[gOk.argv.indexOf('--modules') + 1] === 'i18n-bilingual,web-analytics');
ok('CRITICAL: argv NEVER contains --force', !gOk.argv.includes('--force'));
const gBase = buildGenerateArgs({ name: 'acme', base: 'fullstack', db: 'none' });
ok('valid base payload accepted', gBase.ok === true && gBase.argv.includes('--base'));
ok('base payload also has NO --force', !gBase.argv.includes('--force'));
ok('subdomain defaults to name when omitted', gBase.argv[gBase.argv.indexOf('--subdomain') + 1] === 'acme');

// Rejections — every bad field is REFUSED with 400 (never sanitized-and-run).
const gBad = (name, p) => ok(name, buildGenerateArgs(p).ok === false && buildGenerateArgs(p).status === 400);
gBad('reject UPPERCASE slug', { name: 'Acme', preset: 'clinic', db: 'none' });
gBad('reject trailing-dash slug', { name: 'acme-', preset: 'clinic', db: 'none' });
gBad('reject path-traversal name', { name: '../etc', preset: 'clinic', db: 'none' });
gBad('reject slash in name', { name: 'a/b', preset: 'clinic', db: 'none' });
gBad('reject shell-metachar name', { name: 'a;rm', preset: 'clinic', db: 'none' });
gBad('reject command-substitution name', { name: 'a$(id)', preset: 'clinic', db: 'none' });
gBad('reject unknown preset', { name: 'ok', preset: 'wordpress', db: 'none' });
gBad('reject unknown base', { name: 'ok', base: 'rails', db: 'none' });
gBad('reject unknown module', { name: 'ok', preset: 'clinic', db: 'none', modules: ['rootkit'] });
gBad('reject dev-only hello-module via API', { name: 'ok', preset: 'clinic', db: 'none', modules: ['hello-module'] });
gBad('reject bad subdomain', { name: 'ok', preset: 'clinic', db: 'none', subdomain: '-bad-' });
gBad('reject invalid db', { name: 'ok', preset: 'clinic', db: 'oracle' });
gBad('reject invalid locale', { name: 'ok', preset: 'clinic', db: 'none', locale: 'fr' });
gBad('reject BOTH preset and base', { name: 'ok', preset: 'clinic', base: 'fullstack', db: 'none' });
gBad('reject NEITHER preset nor base', { name: 'ok', db: 'none' });
gBad('reject non-array modules', { name: 'ok', preset: 'clinic', db: 'none', modules: 'i18n-bilingual' });
gBad('reject non-object payload', null);

// No matter the (valid) input, --force is never produced — exhaustive sweep.
let everForce = false;
for (const p of [
  { name: 'a-one', preset: 'clinic', db: 'postgres', modules: ['bookings'] },
  { name: 'b-two', base: 'dotnet-api', db: 'mysql' },
  { name: 'c-three', preset: 'real-estate', db: 'mongo', locale: 'en', subdomain: 'c3' },
]) { const r = buildGenerateArgs(p); if (r.ok && r.argv.includes('--force')) everForce = true; }
ok('no valid payload EVER yields --force', everForce === false);

// assertSafeGenerateArgv: accepts the modules-CSV argv, rejects any metacharacter.
ok('safe-generate accepts the built argv', (() => { try { assertSafeGenerateArgv(gOk.argv); return true; } catch { return false; } })());
ok('safe-generate accepts a modules CSV token', (() => { try { assertSafeGenerateArgv(['--modules', 'a,b,c']); return true; } catch { return false; } })());
let gThrew = false; try { assertSafeGenerateArgv(['create-project', '--name', 'a;rm -rf /']); } catch { gThrew = true; }
ok('safe-generate rejects shell metacharacters', gThrew);
gThrew = false; try { assertSafeGenerateArgv(['create-project', '--name', '$(whoami)']); } catch { gThrew = true; }
ok('safe-generate rejects command substitution', gThrew);

// executeGenerate: maps host exit codes to HTTP codes WITHOUT a real host (seam).
const genCfg = getConfig({});
const fakeRun = (rc, out = '') => async () => ({ rc, stdout: out, stderr: '' });
const okCreate = await executeGenerate({ payload: { name: 'noor', preset: 'clinic', db: 'none' }, identity: 'nawaf', config: genCfg, deps: { run: fakeRun(0, 'scaffolded') } });
eq('executeGenerate success -> 200', okCreate.status, 200);
const conflict = await executeGenerate({ payload: { name: 'noor', preset: 'clinic', db: 'none' }, identity: 'nawaf', config: genCfg, deps: { run: fakeRun(GENERATE_CONFLICT_RC) } });
eq('executeGenerate existing name -> 409 conflict', conflict.status, 409);
const hostErr = await executeGenerate({ payload: { name: 'noor', preset: 'clinic', db: 'none' }, identity: 'nawaf', config: genCfg, deps: { run: fakeRun(1, 'boom') } });
eq('executeGenerate host error -> 502', hostErr.status, 502);
const valErr = await executeGenerate({ payload: { name: 'BAD', preset: 'clinic', db: 'none' }, identity: 'nawaf', config: genCfg, deps: { run: async () => { throw new Error('host MUST NOT be called'); } } });
eq('executeGenerate bad field -> 400 (no host call)', valErr.status, 400);
const dry = await executeGenerate({ payload: { name: 'noor', preset: 'clinic', db: 'none' }, identity: 'nawaf', config: genCfg, dryRun: true, deps: { run: async () => { throw new Error('host MUST NOT be called'); } } });
eq('executeGenerate dryRun -> 200 (no host call)', dry.status, 200);

// ===========================================================================
section('CREATE-PROJECT — JS allowlists match the bridge (bot-lib.sh)');
// ---------------------------------------------------------------------------
// Cross-checked against bot-lib.sh in run.sh (bash). Here: shapes are sane.
ok('generate name shape valid for a real slug', gIsValidName('al-shifa-clinic'));
ok('generate name shape rejects a bad slug', !gIsValidName('Bad_Name'));
ok('generate subdomain accepts a DNS label', gIsValidSub('noor'));
ok('generate subdomain rejects an underscore', !gIsValidSub('no_or'));
eq('4 presets', G_PRESETS.length, 4);
eq('3 bases', G_BASES.length, 3);
eq('4 dbs', G_DBS.length, 4);
eq('2 locales', G_LOCALES.length, 2);
eq('8 curated modules', G_MODULES.length, 8);
ok('hello-module is NOT in the curated allowlist', !G_MODULES.includes('hello-module'));

// ===========================================================================
section('PART #4 — Monitoring/Growth feeds are READ-ONLY (no new write capability)');
// ---------------------------------------------------------------------------
// Every new panel-data action maps to a bot-exec read action, returns an ARGV
// ARRAY, is classified READ-ONLY, and takes NO argument. None introduces a
// write/mutation path (they all flow to scripts/panel-read.sh, which only reads).
const READ_FEEDS = ['monitoring', 'monitoring-alerts', 'backup-status', 'growth-seo', 'growth-prospects'];
const READ_BOT_ACTIONS = ['monitor_metrics', 'monitor_alerts', 'backup_status', 'seo_audits', 'prospects_list'];
for (const a of READ_FEEDS) {
  const r = buildBridgeArgs(a);
  ok(`${a}: builds an argv array`, r.ok && Array.isArray(r.argv) && r.argv.length === 1);
  ok(`${a}: maps to a bot-exec read action`, READ_BOT_ACTIONS.includes(r.argv[0]));
  ok(`${a}: classified read-only`, r.class === 'readonly' && isReadonlyAction(a));
  ok(`${a}: takes NO argument`, buildBridgeArgs(a, 'x').ok === false);
}
ok('all read feeds are in READONLY_ACTIONS', READ_FEEDS.every((a) => READONLY_ACTIONS.includes(a)));
// Defence in depth: assertSafeArgv accepts the (single-token) read argv.
ok('read argv passes assertSafeArgv', (() => { try { assertSafeArgv(['monitor_metrics']); return true; } catch { return false; } })());

// ===========================================================================
section('PART #4 — analytics (Umami) summary: configured-or-not, secrets stay server-side');
// ---------------------------------------------------------------------------
ok('analytics NOT configured when env empty', !isAnalyticsConfigured(getConfig({}).analytics));
const anCfg = getConfig({
  CONTROL_API_ANALYTICS_UMAMI_URL: 'http://umami:3000',
  CONTROL_API_ANALYTICS_UMAMI_USERNAME: 'u',
  CONTROL_API_ANALYTICS_UMAMI_PASSWORD: 'p',
  CONTROL_API_ANALYTICS_WEBSITE_ID: 'w-1',
});
ok('analytics configured when all four set', isAnalyticsConfigured(anCfg.analytics));
eq('read rate-limit has a generous default', getConfig({}).readRateLimit.max, 300);

// not configured -> { configured:false } and NEVER calls fetch.
let fetchCalled = false;
const notConf = await fetchUmamiSummary(getConfig({}), { fetch: async () => { fetchCalled = true; return {}; } });
ok('unconfigured analytics returns configured:false', notConf.configured === false);
ok('unconfigured analytics never hit the network', fetchCalled === false);

// configured + a fake Umami -> mapped raw aggregates (no creds leak to the result).
const resp = (obj) => ({ ok: true, status: 200, json: async () => obj });
const fakeUmami = async (url) => {
  if (url.endsWith('/api/auth/login')) return resp({ token: 'SECRET-TOKEN' });
  if (url.includes('/stats')) return resp({ pageviews: { value: 100, prev: 80 }, visitors: { value: 60, prev: 50 } });
  if (url.includes('/pageviews')) return resp({ pageviews: [{ x: 'd1', y: 10 }], sessions: [{ x: 'd1', y: 8 }, { x: 'd2', y: 12 }] });
  if (url.includes('type=url')) return resp([{ x: '/', y: 40 }, { x: '/p', y: 20 }]);
  if (url.includes('type=referrer')) return resp([{ x: 'google', y: 15 }]);
  if (url.includes('type=country')) return resp([{ x: 'SA', y: 50 }]);
  return resp({});
};
const anOk = await fetchUmamiSummary(anCfg, { fetch: fakeUmami, now: 1700000000000 });
ok('configured analytics returns ok', anOk.configured === true && anOk.ok === true);
ok('visitors mapped from stats', anOk.raw.visitors === 60 && anOk.raw.prevVisitors === 50);
ok('series mapped from sessions', Array.isArray(anOk.raw.series) && anOk.raw.series.length === 2);
ok('top urls/referrers/countries carried', anOk.raw.urls.length === 2 && anOk.raw.referrers.length === 1 && anOk.raw.countries.length === 1);
ok('the umami token NEVER appears in the result', !JSON.stringify(anOk).includes('SECRET-TOKEN'));

// configured but login fails -> ok:false (panel shows an error, not "not configured").
const anFail = await fetchUmamiSummary(anCfg, { fetch: async (url) => (url.endsWith('/api/auth/login') ? { ok: false, status: 401, json: async () => ({}) } : resp({})) });
ok('login failure -> configured:true, ok:false', anFail.configured === true && anFail.ok === false);

// --- tally -----------------------------------------------------------------
console.log(`\n  ${run} run, ${failed ? R : G}${failed} failed${O}`);
process.exit(failed ? 1 : 0);
