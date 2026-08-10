// pi-system prospect organizer — OPTIONAL operator NOTIFY seam (swappable).
// ===========================================================================
// Pushes a heads-up to the OPERATOR, mirroring the swappable notifier used by
// services/seo/engine/notify.js and health-monitor. Two flavours share the SAME
// seam (the SAME env vars + the SAME injectable deps):
//
//   notifyOperator(...)   a one-line "you have follow-ups due" reminder
//                         -> default file <root>/last-followups.txt
//   notifyAnalysis(...)   a RICH "prospect analysis complete" alert (see alert.js)
//                         -> default file <root>/last-analysis-alert.txt
//
// All paths are optional and silent by default — with nothing configured each just
// writes its local file the operator (or Uptime Kuma) can watch:
//
//   PROSPECTS_UPTIME_KUMA_PUSH_URL   ping an Uptime Kuma "push" monitor
//   PROSPECTS_NOTIFY_CMD             run your own command; message on stdin, a short
//                                    label as $1 (e.g. reuse the Telegram bot bridge
//                                    to message YOURSELF). Keep tokens out of git.
//
// CRITICAL BOUNDARY: every flavour is a message TO THE OPERATOR (their own channel —
// e.g. their own Telegram). It is NEVER an outbound message to a prospect: the text is
// the operator's own pipeline counts / their own analysis summary, and there is no
// prospect address/handle anywhere in this path. The command/HTTP calls are isolated
// behind injectable deps so this is testable without spawning processes or requests.
// ===========================================================================

import { writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';

// Best-effort GET with a short TIME cap so a hung notifier endpoint can never block
// the pipeline. Each caller wraps this in try/catch, so an abort/timeout is silently
// ignored (the local file was already written).
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

export async function notifyOperator(root, summaryLine, count, env = process.env, deps = {}) {
  const result = { wrote: null, kuma: false, cmd: false, count };

  // 1) Always write a local reminder file (the zero-config default).
  try {
    mkdirSync(root, { recursive: true });
    const file = join(root, 'last-followups.txt');
    writeFileSync(file, `${summaryLine}\n`, 'utf8');
    result.wrote = file;
  } catch {
    // never fatal — a reminder must not break the pipeline.
  }

  // 2) Optional Uptime Kuma push monitor (operator's own dashboard).
  const kumaUrl = String(env.PROSPECTS_UPTIME_KUMA_PUSH_URL || '').trim();
  if (kumaUrl) {
    const fetchImpl = deps.fetchImpl || globalThis.fetch;
    if (typeof fetchImpl === 'function') {
      const status = count > 0 ? 'up' : 'up'; // informational; due follow-ups are not a fault
      const u = new URL(kumaUrl);
      u.searchParams.set('status', status);
      u.searchParams.set('msg', summaryLine);
      try { await pingWithTimeout(fetchImpl, u.toString()); result.kuma = true; } catch { /* best-effort */ }
    }
  }

  // 3) Optional custom command: `<cmd> <COUNT>` with the summary on stdin. The
  // operator points this at their OWN channel (e.g. the Telegram bot bridge) to
  // remind THEMSELVES — it is never wired to a prospect.
  const cmd = String(env.PROSPECTS_NOTIFY_CMD || '').trim();
  if (cmd) {
    const spawnImpl = deps.spawnImpl;
    if (typeof spawnImpl === 'function') {
      try { spawnImpl(cmd, [String(count)], summaryLine); result.cmd = true; } catch { /* best-effort */ }
    }
  }

  return result;
}

// notifyAnalysis(root, alert, env, deps) — deliver the RICH post-analysis operator
// alert through the SAME seam as notifyOperator (same env vars, same injectable deps).
//   alert = { full, summary, label }
//     full     the multi-line alert text (alert.js formatProspectAlert) — written to
//              the file and piped to PROSPECTS_NOTIFY_CMD on stdin.
//     summary  a one-line summary (formatProspectAlertSummary) — the Kuma "msg".
//     label    a short token (e.g. the tier) passed to the command as $1.
// Best-effort and silent by default: with nothing configured it only writes the local
// file. It NEVER throws and NEVER contacts the prospect — same boundary as above.
export async function notifyAnalysis(root, alert = {}, env = process.env, deps = {}) {
  const full = String(alert.full || '');
  const summary = String(alert.summary || full.split('\n')[0] || '');
  const label = String(alert.label || 'analysis');
  const result = { wrote: null, kuma: false, cmd: false, label };

  // 1) Always write a local alert file (the zero-config default).
  try {
    mkdirSync(root, { recursive: true });
    const file = join(root, 'last-analysis-alert.txt');
    writeFileSync(file, `${full}\n`, 'utf8');
    result.wrote = file;
  } catch {
    // never fatal — an alert must not break the analysis (already saved).
  }

  // 2) Optional Uptime Kuma push (operator's own dashboard). A completed analysis is
  // informational, not a fault, so it always reports "up" with the one-line summary.
  const kumaUrl = String(env.PROSPECTS_UPTIME_KUMA_PUSH_URL || '').trim();
  if (kumaUrl) {
    const fetchImpl = deps.fetchImpl || globalThis.fetch;
    if (typeof fetchImpl === 'function') {
      const u = new URL(kumaUrl);
      u.searchParams.set('status', 'up');
      u.searchParams.set('msg', summary);
      try { await pingWithTimeout(fetchImpl, u.toString()); result.kuma = true; } catch { /* best-effort */ }
    }
  }

  // 3) Optional custom command: `<cmd> <LABEL>` with the FULL alert on stdin. The
  // operator points this at their OWN channel (e.g. the Telegram bot bridge) to
  // message THEMSELVES — it is never wired to a prospect.
  const cmd = String(env.PROSPECTS_NOTIFY_CMD || '').trim();
  if (cmd) {
    const spawnImpl = deps.spawnImpl;
    if (typeof spawnImpl === 'function') {
      try { spawnImpl(cmd, [label], full); result.cmd = true; } catch { /* best-effort */ }
    }
  }

  return result;
}
