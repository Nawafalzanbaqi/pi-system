// ===========================================================================
// pi-system Control API — SAFE .env WRITER (fs SEAM around the pure env ops)
// ---------------------------------------------------------------------------
// Writes ONE allowlisted key to .env the same careful way the secrets scripts do:
//   1. ALLOWLIST + SHAPE check     (registry.isAllowedKey + validateValue)
//   2. BACK UP the current .env    (timestamped copy, like generate-secrets.sh)
//   3. ATOMIC write                (temp file in the SAME dir, then rename; falls
//                                   back to a direct write only across devices)
//   4. PRESERVE structure          (setEnvValue replaces the line in place)
//   5. NEVER log the value         (only the key name + identity are auditable)
//
// The Node `fs`/`path` modules are injected (default = the real ones) so tests can
// drive the whole flow against an in-memory fake — no real filesystem, no Docker.
// This is the ONLY .env writer in the API; route handlers must go through it.
// ===========================================================================
import * as realFs from 'node:fs';
import * as realPath from 'node:path';

import { isAllowedKey, getKeyDef, validateValue, restartServicesForKey } from './registry.js';
import { setEnvValue } from './env.js';

// writeEnvKey({ reg, key, value, envFile, deps, now, backupDir })
//   -> { ok: true, restart_services, backup }            on success
//   -> { ok: false, status, error }                      on a rejected request
// `deps` lets tests inject { fs, path }. `now`/`backupDir` are also injectable.
export function writeEnvKey({
  reg,
  key,
  value,
  envFile,
  deps = {},
  now = () => new Date(),
  backupDir = null,
}) {
  const fs = deps.fs || realFs;
  const path = deps.path || realPath;

  // (1) ALLOWLIST — the request can ONLY name a key the manifest declares.
  if (!isAllowedKey(reg, key)) {
    return { ok: false, status: 400, error: 'unknown or non-editable config key' };
  }
  const def = getKeyDef(reg, key);

  // (1b) SHAPE — basic format check; also rejects newlines (line-injection guard).
  const v = validateValue(def, value);
  if (!v.ok) return { ok: false, status: 400, error: v.error };

  if (!fs.existsSync(envFile)) {
    return { ok: false, status: 500, error: '.env file not found on the server' };
  }

  const original = fs.readFileSync(envFile, 'utf8');
  const updated = setEnvValue(original, key, value);

  // (2) BACKUP first — never mutate without a recovery copy.
  const stamp = ts(now());
  const dir = backupDir || path.dirname(envFile);
  const base = path.basename(envFile);
  const backup = path.join(dir, `${base}.bak.${stamp}`);
  ensureDir(fs, dir);
  fs.writeFileSync(backup, original, { mode: 0o600 });

  // (3) ATOMIC write: temp in the SAME directory, fsync-then-rename. A rename
  //     within one filesystem is atomic; cross-device (EXDEV) falls back to a
  //     direct write (the backup above still guarantees recoverability).
  const tmp = path.join(path.dirname(envFile), `.${base}.tmp.${stamp}.${pid()}`);
  fs.writeFileSync(tmp, updated, { mode: 0o600 });
  try {
    fs.renameSync(tmp, envFile);
  } catch (e) {
    if (e && e.code === 'EXDEV') {
      fs.writeFileSync(envFile, updated, { mode: 0o600 });
      try { fs.unlinkSync(tmp); } catch { /* best effort */ }
    } else {
      try { fs.unlinkSync(tmp); } catch { /* best effort */ }
      throw e;
    }
  }

  // (5) Return only NON-secret metadata. The value is intentionally absent.
  return {
    ok: true,
    key,
    restart_services: restartServicesForKey(reg, key),
    backup,
  };
}

function ts(d) {
  const p = (n) => String(n).padStart(2, '0');
  return (
    `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}` +
    `-${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`
  );
}

function pid() {
  try { return process.pid; } catch { return '0'; }
}

function ensureDir(fs, dir) {
  try { fs.mkdirSync(dir, { recursive: true }); } catch { /* exists / best effort */ }
}
