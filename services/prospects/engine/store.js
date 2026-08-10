// pi-system prospect organizer — the file-backed, server-less STORE.
// ===========================================================================
// WHY file-backed and not an always-on database server (same Pi-aware reasoning as
// services/seo/engine/store.js, the quality gate, and the backup/health-monitor):
// a freelancer's prospect pipeline is a handful of records touched a few times a
// day. Running a Postgres/MySQL container 24/7 (256-512 MB of RAM) purely to hold
// that is exactly the always-on cost this platform avoids. So the data lives on the
// SSD under data/prospects/ (git-ignored): internal-only by nature (a local file,
// no network, no host ports), it survives restarts and costs zero RAM when idle.
//
// WHY a single JSON DOCUMENT here (and not append-only JSONL like the SEO store):
// SEO audits are IMMUTABLE historical events — you never edit a past audit — so an
// append-only log is the right shape there. Prospects are MUTABLE ENTITIES (status
// changes, notes accrue, follow-up dates move), so the current state of all
// prospects is kept in ONE small JSON document keyed by id. Each record still
// carries its own history (statusHistory[] + notes[]) for an audit trail. The file
// is tiny and rewritten in full on each change.
//
//   <root>/prospects.json            the whole pipeline ({ schema, prospects:{id:rec} })
//   <root>/reports/<id>-<ts>.md      a saved public-site analysis report (per run)
//   <root>/last-followups.txt        the latest operator follow-up reminder (notify.js)
//
// Pure-ish: every function takes the store root explicitly (no globals), so the
// store logic is unit-testable against a temp dir with no Docker.
// ===========================================================================

import { mkdirSync, writeFileSync, readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { isValidId, slugify } from './pipeline.js';

function ensureDir(d) {
  mkdirSync(d, { recursive: true });
  return d;
}

export function paths(root) {
  return {
    dbFile: join(root, 'prospects.json'),
    reportsDir: join(root, 'reports'),
  };
}

const EMPTY_DB = { schema: 1, prospects: {} };

// Load the whole pipeline document. Missing/corrupt file => a fresh empty DB
// (never throws — a missing store just means no prospects yet).
export function loadDb(root) {
  const { dbFile } = paths(root);
  if (!existsSync(dbFile)) return { ...EMPTY_DB, prospects: {} };
  try {
    const parsed = JSON.parse(readFileSync(dbFile, 'utf8'));
    if (!parsed || typeof parsed !== 'object' || typeof parsed.prospects !== 'object') {
      return { ...EMPTY_DB, prospects: {} };
    }
    return { schema: parsed.schema || 1, prospects: parsed.prospects || {} };
  } catch {
    return { ...EMPTY_DB, prospects: {} };
  }
}

// Persist the whole document. The file is small; rewriting it in full is simplest
// and matches the SEO store's plain-write approach (cross-platform safe).
export function saveDb(root, db) {
  ensureDir(root);
  const { dbFile } = paths(root);
  const out = { schema: db.schema || 1, prospects: db.prospects || {} };
  writeFileSync(dbFile, JSON.stringify(out, null, 2) + '\n', 'utf8');
  return dbFile;
}

export function getProspect(db, id) {
  return (db && db.prospects && db.prospects[id]) || null;
}

// All prospects as an array, newest-created first (stable, deterministic).
export function listProspects(db, filter = {}) {
  const all = Object.values((db && db.prospects) || {});
  let out = all;
  if (filter.status) out = out.filter((r) => r.status === filter.status);
  return out.sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)));
}

// Insert/replace a record by its id (mutates db in place; caller persists).
export function putProspect(db, record) {
  if (!isValidId(record.id)) throw new Error(`invalid prospect id '${record.id}'`);
  db.prospects[record.id] = record;
  return db;
}

// Derive a unique id from a business name: slugify, then suffix -2, -3, ... if the
// slug is already taken. Guarantees the result satisfies isValidId.
export function uniqueId(db, name) {
  const base = slugify(name);
  if (!getProspect(db, base)) return base;
  for (let i = 2; i < 1000; i += 1) {
    const cand = `${base}-${i}`.slice(0, 40).replace(/-+$/g, '');
    if (!getProspect(db, cand)) return cand;
  }
  throw new Error(`could not derive a unique id from '${name}'`);
}

// Write a saved analysis report file; returns its path. The report is the SEO
// engine's Markdown output (see analyze.js) — a shareable artifact the operator
// reads, edits and sends THEMSELVES.
export function writeReport(root, id, timestamp, text) {
  if (!isValidId(id)) throw new Error(`invalid prospect id '${id}'`);
  const { reportsDir } = paths(root);
  ensureDir(reportsDir);
  const safeTs = String(timestamp).replace(/[:.]/g, '-');
  const file = join(reportsDir, `${id}-${safeTs}.md`);
  writeFileSync(file, text, 'utf8');
  return file;
}

// Write a sibling report ARTIFACT (the OPTIONAL PDF export's .html/.pdf) next to the
// .md report under reports/, with the SAME `<id>-<ts>` stem so the trio is grouped.
// `data` is a string (html) or a Buffer (pdf). Mirrors the SEO store's
// writeReportArtifact so the reused pdf-export path lands files the same way here.
export function writeReportArtifact(root, id, timestamp, ext, data) {
  if (!isValidId(id)) throw new Error(`invalid prospect id '${id}'`);
  if (!/^[a-z0-9]{1,8}$/.test(String(ext))) throw new Error(`invalid artifact extension: '${ext}'`);
  const { reportsDir } = paths(root);
  ensureDir(reportsDir);
  const safeTs = String(timestamp).replace(/[:.]/g, '-');
  const file = join(reportsDir, `${id}-${safeTs}.${ext}`);
  writeFileSync(file, data); // string -> utf8; Buffer -> binary (PDF-safe)
  return file;
}
