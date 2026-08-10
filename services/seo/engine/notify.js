// pi-system SEO engine — OPTIONAL swappable notifier (same pattern as health-monitor).
// ===========================================================================
// After an audit, optionally push a one-line summary somewhere. Mirrors the
// swappable notifier used by health-monitor.sh / the n8n health workflow, so the
// SEO audit can share the operator's existing alert channel (e.g. the Telegram
// management bot) without inventing a new one. ALL paths are optional and silent
// by default — with nothing configured, notify() just writes a local file.
//
//   default                       write <root>/last-summary.txt (operator/Kuma can watch)
//   SEO_UPTIME_KUMA_PUSH_URL      ping an Uptime Kuma "push" monitor (up/down by severity)
//   SEO_NOTIFY_CMD                run your own command; summary on stdin, verdict as $1
//
// The command/HTTP calls are isolated behind injectable deps so this is testable
// without spawning processes or making requests.
// ===========================================================================

import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

// Best-effort GET with a short TIME cap so a hung notifier endpoint can never block
// the audit. The caller wraps this in try/catch, so an abort/timeout is silently
// ignored (the local summary file was already written).
const NOTIFY_TIMEOUT_MS = 5000;
async function pingWithTimeout(fetchImpl, url, timeoutMs = NOTIFY_TIMEOUT_MS) {
  const ac = typeof AbortController !== 'undefined' ? new AbortController() : null;
  const timer = ac ? setTimeout(() => ac.abort(), timeoutMs) : null;
  try {
    return await fetchImpl(url, ac ? { signal: ac.signal } : undefined);
  } finally {
    if (timer) clearTimeout(timer);
  }
}

// Pick a coarse verdict from the findings counts (used by Kuma up/down).
export function verdictFromCounts(counts) {
  if ((counts.critical || 0) > 0) return 'CRITICAL';
  if ((counts.high || 0) > 0) return 'WARN';
  return 'OK';
}

export async function notify(root, summaryLine, counts, env = process.env, deps = {}) {
  const verdict = verdictFromCounts(counts);
  const result = { wrote: null, kuma: false, cmd: false, verdict };

  // 1) Always write a local summary file (the zero-config default).
  try {
    mkdirSync(root, { recursive: true });
    const file = join(root, 'last-summary.txt');
    writeFileSync(file, `[${verdict}] ${summaryLine}\n`, 'utf8');
    result.wrote = file;
  } catch {
    // never fatal
  }

  // 2) Optional Uptime Kuma push monitor.
  const kumaUrl = String(env.SEO_UPTIME_KUMA_PUSH_URL || '').trim();
  if (kumaUrl) {
    const fetchImpl = deps.fetchImpl || globalThis.fetch;
    if (typeof fetchImpl === 'function') {
      const status = verdict === 'CRITICAL' ? 'down' : 'up';
      const u = new URL(kumaUrl);
      u.searchParams.set('status', status);
      u.searchParams.set('msg', summaryLine);
      try { await pingWithTimeout(fetchImpl, u.toString()); result.kuma = true; } catch { /* best-effort */ }
    }
  }

  // 3) Optional custom command: `<cmd> <VERDICT>` with the summary on stdin.
  const cmd = String(env.SEO_NOTIFY_CMD || '').trim();
  if (cmd) {
    const spawnImpl = deps.spawnImpl;
    if (typeof spawnImpl === 'function') {
      try { spawnImpl(cmd, [verdict], summaryLine); result.cmd = true; } catch { /* best-effort */ }
    }
  }

  return result;
}
