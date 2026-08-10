// pi-system prospect organizer — the PIPELINE, pure deterministic logic.
// ===========================================================================
// The heart of the CRM-lite: how a prospect RECORD is created and how it moves
// through the operator's MANUAL acquisition pipeline. Everything here is PURE —
// no I/O, no clock, no network, no randomness (the timestamp is passed in) — so
// the state machine is unit-testable without Docker, and the store layer is the
// only thing that touches disk.
//
// ETHICAL/LEGAL BOUNDARY (architectural, not a toggle): a prospect record is data
// the OPERATOR enters by hand about a business they found themselves. NOTHING in
// this module (or anywhere in this engine) harvests data from Google Maps,
// LinkedIn, search results, or any ToS-protected platform, and NOTHING sends a
// message to a prospect. This module only organizes the operator's own notes and
// the pipeline status. Outreach is done MANUALLY by the operator, off-platform.
// ===========================================================================

// The pipeline stages, in funnel order. `won`/`lost` are the closed outcomes.
export const STATUSES = ['new', 'contacted', 'in-talks', 'won', 'lost'];

// Closed stages — a prospect here is done and is excluded from due follow-ups.
export const CLOSED_STATUSES = ['won', 'lost'];

// Allowed status transitions. Deliberately explicit (not "anything to anything")
// so the funnel is meaningful and the test can assert it: you must CONTACT before
// you can be IN-TALKS or WIN; closed deals can be re-opened/re-engaged. Same map
// is mirrored in scripts/lib/prospects-lib.sh for the shell side.
export const TRANSITIONS = {
  new: ['contacted', 'lost'],
  contacted: ['in-talks', 'won', 'lost', 'new'],
  'in-talks': ['won', 'lost', 'contacted'],
  won: ['in-talks'], // re-open a closed-won deal
  lost: ['new', 'contacted'], // re-engage a previously lost prospect
};

const NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/; // the storage id rule (matches seo store)
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/; // follow-up dates are plain ISO calendar dates

export function isValidStatus(s) {
  return typeof s === 'string' && STATUSES.includes(s);
}

export function isClosed(s) {
  return CLOSED_STATUSES.includes(s);
}

// id (the storage key) follows the same rule the SEO store + project generator use.
export function isValidId(id) {
  return typeof id === 'string' && NAME_RE.test(id);
}

// A follow-up date is a calendar date (YYYY-MM-DD) that actually exists.
export function isValidDate(d) {
  if (typeof d !== 'string' || !DATE_RE.test(d)) return false;
  const dt = new Date(d + 'T00:00:00Z');
  return !Number.isNaN(dt.getTime()) && dt.toISOString().slice(0, 10) === d;
}

// A prospect's PUBLIC website URL. Optional on a record, but when present it must
// be a real http(s) URL — the only thing the analyzer will ever fetch (the
// prospect's own public site, like any visitor). No other scheme is accepted.
export function isValidUrl(u) {
  if (typeof u !== 'string' || u.trim() === '') return false;
  try {
    const parsed = new URL(u.trim());
    return parsed.protocol === 'http:' || parsed.protocol === 'https:';
  } catch {
    return false;
  }
}

// Turn a free-text business name into an id candidate that satisfies isValidId.
// e.g. "Acme Dental Clinic!" -> "acme-dental-clinic". The store resolves clashes.
export function slugify(name) {
  const base = String(name || '')
    .toLowerCase()
    .normalize('NFKD')
    .replace(/[^a-z0-9]+/g, '-') // non-alphanumerics -> hyphen
    .replace(/^-+|-+$/g, '') // trim leading/trailing hyphens
    .replace(/-{2,}/g, '-'); // collapse runs
  let s = base.replace(/^[^a-z]+/, ''); // id must start with a letter
  if (s.length < 2) s = (s + '-prospect').slice(0, 40);
  s = s.slice(0, 40).replace(/-+$/g, ''); // keep <=40, no trailing hyphen
  return s;
}

// Can a prospect move from `from` to `to`? Pure boolean — no throwing.
export function canTransition(from, to) {
  if (!isValidStatus(from) || !isValidStatus(to)) return false;
  if (from === to) return false; // a no-op is not a transition
  return (TRANSITIONS[from] || []).includes(to);
}

// ---------------------------------------------------------------------------
// createProspect(fields, ctx) -> a fresh prospect record.
//   fields = { name, url?, status?, note? }   (operator-entered)
//   ctx    = { id, now }                       (id resolved-unique by the store;
//                                               now = ISO timestamp string)
// Throws on invalid input so the CLI can report a clear error. Pure given ctx.
// ---------------------------------------------------------------------------
export function createProspect(fields = {}, ctx = {}) {
  const name = String(fields.name || '').trim();
  if (!name) throw new Error('a prospect needs a business name (--name)');
  const id = String(ctx.id || '').trim();
  if (!isValidId(id)) throw new Error(`invalid resolved id '${id}'`);
  const now = String(ctx.now || new Date().toISOString());

  const status = fields.status === undefined || fields.status === '' ? 'new' : String(fields.status);
  if (!isValidStatus(status)) {
    throw new Error(`invalid status '${status}' (one of: ${STATUSES.join(', ')})`);
  }

  const url = fields.url === undefined || fields.url === null || fields.url === '' ? null : String(fields.url).trim();
  if (url !== null && !isValidUrl(url)) {
    throw new Error(`invalid website URL '${url}' (must be an http(s) URL — the prospect's own public site)`);
  }

  const notes = [];
  if (fields.note && String(fields.note).trim()) {
    notes.push({ ts: now, text: String(fields.note).trim() });
  }

  return {
    schema: 1,
    id,
    name,
    url,
    status,
    notes,
    followup: null,
    lastAnalysis: null, // pointer to the most recent public-site analysis report
    createdAt: now,
    updatedAt: now,
    statusHistory: [{ ts: now, from: null, to: status }],
  };
}

// Move a prospect to a new status (validated transition). Returns a NEW record.
export function setStatus(record, to, now) {
  const from = record.status;
  if (!isValidStatus(to)) throw new Error(`invalid status '${to}' (one of: ${STATUSES.join(', ')})`);
  if (from === to) throw new Error(`prospect '${record.id}' is already '${to}'`);
  if (!canTransition(from, to)) {
    throw new Error(`cannot move '${record.id}' from '${from}' to '${to}' (allowed: ${(TRANSITIONS[from] || []).join(', ') || 'none'})`);
  }
  const ts = String(now || new Date().toISOString());
  return {
    ...record,
    status: to,
    updatedAt: ts,
    statusHistory: [...(record.statusHistory || []), { ts, from, to }],
  };
}

// Append a note (operator's own observations). Returns a NEW record.
export function addNote(record, text, now) {
  const t = String(text || '').trim();
  if (!t) throw new Error('a note needs some text (--text)');
  const ts = String(now || new Date().toISOString());
  return {
    ...record,
    notes: [...(record.notes || []), { ts, text: t }],
    updatedAt: ts,
  };
}

// Set or clear the follow-up reminder date. `value` is a YYYY-MM-DD date, or the
// literal 'clear'/null/'' to remove it. Returns a NEW record. The reminder is for
// the OPERATOR (surfaced by `followups`), never an outbound message to anyone.
export function setFollowup(record, value, now) {
  const ts = String(now || new Date().toISOString());
  if (value === null || value === undefined || value === '' || value === 'clear' || value === 'none') {
    return { ...record, followup: null, updatedAt: ts };
  }
  const d = String(value).trim();
  if (!isValidDate(d)) throw new Error(`invalid follow-up date '${d}' (use YYYY-MM-DD, or 'clear')`);
  return { ...record, followup: d, updatedAt: ts };
}

// Update editable descriptive fields (name / public URL). Returns a NEW record.
export function setFields(record, fields = {}, now) {
  const ts = String(now || new Date().toISOString());
  const next = { ...record, updatedAt: ts };
  if (fields.name !== undefined) {
    const name = String(fields.name).trim();
    if (!name) throw new Error('name cannot be empty');
    next.name = name;
  }
  if (fields.url !== undefined) {
    if (fields.url === null || fields.url === '' || fields.url === 'clear') {
      next.url = null;
    } else {
      const url = String(fields.url).trim();
      if (!isValidUrl(url)) throw new Error(`invalid website URL '${url}' (must be an http(s) URL)`);
      next.url = url;
    }
  }
  return next;
}

// Record a pointer to a completed public-site analysis (set by the analyze flow).
// Stores only a summary + the report path — the full report lives on disk. The audit's
// `verdict` (overall/tier/opportunity) is kept too so the optional AI decision-assist
// can read it later WITHOUT re-running an analysis (or another network probe).
export function recordAnalysis(record, analysis, now) {
  const ts = String(now || new Date().toISOString());
  return {
    ...record,
    lastAnalysis: {
      ts,
      engine: analysis.engine || null,
      url: analysis.url || record.url || null,
      reportFile: analysis.reportFile || null,
      scores: analysis.scores || null,
      verdict: analysis.verdict || null,
      counts: analysis.counts || null,
      summary: analysis.summary || null,
    },
    updatedAt: ts,
  };
}

// Store the OPTIONAL AI decision-assist result under `ai_assist`. Advisory only — it
// records the AI's suggested lead score / next action / rationale for the OPERATOR to
// read; it changes NOTHING about the pipeline status and contacts no one. Returns a NEW
// record. (Callers only invoke this when the assist actually ran, i.e. assist.enabled.)
export function recordAssist(record, assist, now) {
  const ts = String(now || (assist && assist.ts) || new Date().toISOString());
  return {
    ...record,
    ai_assist: { ...assist, ts: (assist && assist.ts) || ts },
    updatedAt: ts,
  };
}

// Store the OPTIONAL copy-paste DRAFTS (drafts.js) under `drafts`. These are message
// drafts the OPERATOR copies, personalizes, and sends HIMSELF — recording them changes
// NOTHING about the pipeline status and sends nothing. Returns a NEW record.
export function recordDrafts(record, drafts, now) {
  const ts = String(now || (drafts && drafts.ts) || new Date().toISOString());
  return {
    ...record,
    drafts: { ...drafts, ts: (drafts && drafts.ts) || ts },
    updatedAt: ts,
  };
}
