// pi-system SEO engine — the results STORE (file-backed, server-less).
// ===========================================================================
// WHY a file store and not an always-on database server (see services/seo/README):
// audit history is a few rows per site written a handful of times a day. Running a
// Postgres/MySQL container 24/7 (256-512 MB of RAM) purely to hold that would be
// exactly the always-on cost this Pi-aware platform avoids — the same reasoning the
// quality-gate uses to reject an always-on analyser, and the backup/health-monitor
// use to write under data/ instead. So results are stored as APPEND-ONLY JSON Lines
// keyed BY SERVICE NAME, one file per site, under data/seo/ (git-ignored, on the
// SSD): internal-only by nature (a local file, no network, no host ports), it
// survives restarts, costs zero RAM idle, and is trivial to read back for trends.
//
//   <root>/audits/<name>.jsonl      append-only history (one audit JSON per line)
//   <root>/latest/<name>.json       the most recent audit (quick status reads)
//   <root>/reports/<name>-<ts>.md   the human-readable report for a run
//   <root>/reports/<name>-<ts>.html the OPTIONAL PDF export's print-ready HTML
//   <root>/reports/<name>-<ts>.pdf  the OPTIONAL PDF export (only if a renderer is opt-in)
//
// Pure-ish: every function takes the store root explicitly (no globals), so the
// store logic is unit-testable against a temp dir with no Docker.
// ===========================================================================

import { mkdirSync, appendFileSync, writeFileSync, readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// Service-name shape used as the storage key (matches the generator's project-name
// rule): lowercase, letter first, [a-z0-9-], 2-40 chars, no trailing hyphen.
const NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/;

export function isValidName(name) {
  return typeof name === 'string' && NAME_RE.test(name);
}

function ensureDir(d) {
  mkdirSync(d, { recursive: true });
  return d;
}

export function paths(root, name) {
  return {
    auditsDir: join(root, 'audits'),
    latestDir: join(root, 'latest'),
    reportsDir: join(root, 'reports'),
    auditFile: join(root, 'audits', `${name}.jsonl`),
    latestFile: join(root, 'latest', `${name}.json`),
  };
}

// Append one audit to the site's history + update its latest snapshot.
export function appendAudit(root, name, audit) {
  if (!isValidName(name)) throw new Error(`invalid site name: '${name}'`);
  const p = paths(root, name);
  ensureDir(p.auditsDir);
  ensureDir(p.latestDir);
  appendFileSync(p.auditFile, JSON.stringify(audit) + '\n', 'utf8');
  writeFileSync(p.latestFile, JSON.stringify(audit, null, 2) + '\n', 'utf8');
  return p;
}

// Write a rendered report file; returns its path.
export function writeReport(root, name, timestamp, text) {
  if (!isValidName(name)) throw new Error(`invalid site name: '${name}'`);
  const p = paths(root, name);
  ensureDir(p.reportsDir);
  const safeTs = String(timestamp).replace(/[:.]/g, '-');
  const file = join(p.reportsDir, `${name}-${safeTs}.md`);
  writeFileSync(file, text, 'utf8');
  return file;
}

// Write a sibling report ARTIFACT (e.g. the OPTIONAL PDF export's .html/.pdf) next
// to the .md report under reports/, with the SAME `<name>-<ts>` stem so the trio is
// grouped. `data` is a string (html/md) or a Buffer (pdf). Returns the path.
export function writeReportArtifact(root, name, timestamp, ext, data) {
  if (!isValidName(name)) throw new Error(`invalid site name: '${name}'`);
  if (!/^[a-z0-9]{1,8}$/.test(String(ext))) throw new Error(`invalid artifact extension: '${ext}'`);
  const p = paths(root, name);
  ensureDir(p.reportsDir);
  const safeTs = String(timestamp).replace(/[:.]/g, '-');
  const file = join(p.reportsDir, `${name}-${safeTs}.${ext}`);
  writeFileSync(file, data); // string -> utf8; Buffer -> binary (PDF-safe)
  return file;
}

// All stored Markdown report files for a site, oldest..newest. The filenames embed
// the ISO timestamp (with : . -> -), so a lexicographic sort is chronological.
export function listReports(root, name) {
  const p = paths(root, name);
  if (!existsSync(p.reportsDir)) return [];
  const re = new RegExp(`^${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}-\\d{4}-.*\\.md$`);
  return readdirSync(p.reportsDir).filter((f) => re.test(f)).sort().map((f) => join(p.reportsDir, f));
}

// The newest stored Markdown report for a site, or null if none exists.
export function latestReport(root, name) {
  const all = listReports(root, name);
  return all.length ? all[all.length - 1] : null;
}

// Read a site's full audit history (oldest..newest). Missing file => [].
export function readAudits(root, name) {
  const p = paths(root, name);
  if (!existsSync(p.auditFile)) return [];
  const lines = readFileSync(p.auditFile, 'utf8').split('\n').filter((l) => l.trim());
  const out = [];
  for (const line of lines) {
    try { out.push(JSON.parse(line)); } catch { /* skip a corrupt line, never throw */ }
  }
  return out;
}

export function readLatest(root, name) {
  const p = paths(root, name);
  if (!existsSync(p.latestFile)) return null;
  try { return JSON.parse(readFileSync(p.latestFile, 'utf8')); } catch { return null; }
}

// List the site names that have stored history.
export function listSites(root) {
  const dir = join(root, 'audits');
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((f) => f.endsWith('.jsonl'))
    .map((f) => f.slice(0, -'.jsonl'.length))
    .sort();
}

// Load RECENT audits across ALL sites, BOUNDED to the last `perSite` per site (newest
// last in each site's history). Returns a flat array — the input to the content-idea
// aggregator. Bounded so a long history can't blow up memory on the Pi. Local read only.
export function readRecentAuditsAcrossSites(root, opts = {}) {
  const perSite = Number.isFinite(opts.perSite) && opts.perSite > 0 ? Math.floor(opts.perSite) : 5;
  const out = [];
  for (const name of listSites(root)) {
    const hist = readAudits(root, name);
    const recent = hist.slice(-perSite);
    for (const a of recent) if (a && typeof a === 'object') out.push(a);
  }
  return out;
}

// Compute a compact trend from a site's history: first vs latest score per
// category + a per-run score table. Pure given the audits array.
export function trend(audits) {
  const runs = audits.filter((a) => a && a.scores);
  if (runs.length === 0) return { runs: 0, categories: {}, history: [] };
  const cats = ['performance', 'accessibility', 'best-practices', 'seo'];
  const first = runs[0];
  const last = runs[runs.length - 1];
  const categories = {};
  for (const c of cats) {
    const a = Number(first.scores[c]);
    const b = Number(last.scores[c]);
    categories[c] = { first: a, latest: b, delta: Number.isFinite(a) && Number.isFinite(b) ? b - a : null };
  }
  const history = runs.map((a) => ({ timestamp: a.timestamp, scores: a.scores }));
  return { runs: runs.length, categories, history };
}
