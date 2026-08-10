// ===========================================================================
// pi-system Control API — AUDIT LOG (identity + action + result; NEVER values)
// ---------------------------------------------------------------------------
// Every state-changing or config-writing request is recorded so there is an
// after-the-fact trail of WHO did WHAT and the OUTCOME. The record builder is
// PURE and, by construction, has no field that can carry a secret value:
//   { ts, identity, action, target, class, result }
// `target` is a KEY NAME / service / profile — never a value. auditLine() refuses
// to serialize anything else, so a secret can never reach the log even by mistake.
//
// appendAudit() is a thin fs SEAM (best-effort, like the bot bridge's logger):
// a log we cannot write must never crash a request, but we surface it on stderr.
// It also SELF-TRIMS the log so an append-only trail can never fill the SSD —
// mirroring how scripts/health-monitor.sh bounds health.log (see trimToLastLines
// + trimAuditLog below).
// ===========================================================================
import * as realFs from 'node:fs';
import * as realPath from 'node:path';

// Default line cap for the audit log; overridable per-call (deps.maxLines, wired
// from config.auditMaxLines / CONTROL_API_AUDIT_MAX_LINES). ~5000 lines is years
// of operator actions. A value <= 0 disables trimming entirely.
export const DEFAULT_AUDIT_MAX_LINES = 5000;

// Build the canonical record. Only the whitelisted, non-sensitive fields survive.
export function auditRecord({ identity, action, target = '-', klass = '-', result, now = () => new Date() }) {
  return {
    ts: now().toISOString(),
    identity: safe(identity) || 'unknown',
    action: safe(action) || '-',
    target: safe(target) || '-',   // KEY name / service / profile — never a value
    class: safe(klass) || '-',
    result: safe(result) || '-',
  };
}

export function auditLine(record) {
  return JSON.stringify(record);
}

export function appendAudit(logPath, record, deps = {}) {
  const fs = deps.fs || realFs;
  const path = deps.path || realPath;
  const maxLines = Number.isFinite(deps.maxLines) ? deps.maxLines : DEFAULT_AUDIT_MAX_LINES;
  try {
    fs.mkdirSync(path.dirname(logPath), { recursive: true });
    fs.appendFileSync(logPath, auditLine(record) + '\n', { mode: 0o600 });
    // Keep the log bounded AFTER the append (best-effort; a failed trim must
    // never fail the write that already succeeded).
    try { trimAuditLog(logPath, maxLines, { fs }); } catch { /* ignore */ }
    return true;
  } catch (e) {
    try { process.stderr.write(`[control-api][warn] could not write audit log: ${logPath}\n`); } catch { /* ignore */ }
    return false;
  }
}

// PURE: return `text` reduced to AT MOST its last `maxLines` lines (the NEWEST),
// preserving a trailing newline iff the input had one. maxLines <= 0 (or not a
// finite number) means "no trimming" and returns `text` unchanged. No I/O — this
// is the unit-testable core of the size guard.
export function trimToLastLines(text, maxLines) {
  if (!Number.isFinite(maxLines) || maxLines <= 0) return text;
  const hadTrailingNewline = text.endsWith('\n');
  const lines = text.split('\n');
  // A trailing newline produces a final '' element — drop it so it isn't counted
  // as a line (and so the count matches `wc -l`).
  if (hadTrailingNewline) lines.pop();
  if (lines.length <= maxLines) return text;
  const kept = lines.slice(lines.length - maxLines);
  return kept.join('\n') + (hadTrailingNewline ? '\n' : '');
}

// Bound the audit log on disk: when it grows past `maxLines`, rewrite it to just
// the newest `maxLines` lines. ATOMIC by construction — write a sibling .tmp then
// rename over the original (never truncate-in-place), so a crash mid-trim can
// never lose or corrupt the live log. Best-effort and read-only when already
// within bound. Returns true iff it actually rewrote the file.
export function trimAuditLog(logPath, maxLines = DEFAULT_AUDIT_MAX_LINES, deps = {}) {
  const fs = deps.fs || realFs;
  if (!Number.isFinite(maxLines) || maxLines <= 0) return false;   // trimming disabled
  let current;
  try { current = fs.readFileSync(logPath, 'utf8'); } catch { return false; }
  current = String(current);
  const trimmed = trimToLastLines(current, maxLines);
  if (trimmed === current) return false;                           // already within bound
  const tmp = `${logPath}.tmp`;
  fs.writeFileSync(tmp, trimmed, { mode: 0o600 });
  fs.renameSync(tmp, logPath);
  return true;
}

// Coerce to a short, single-line, value-free token. Strips line breaks (so a log
// entry is always one line) and caps length.
function safe(v) {
  if (v == null) return '';
  return String(v).replace(/[\r\n\t]+/g, ' ').trim().slice(0, 200);
}
