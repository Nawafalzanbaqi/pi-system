// wizard-payload.js — PURE builder: New-Project wizard selections -> the exact
// generate payload that POST /api/projects accepts. Project creation IS now wired
// (control-panel part #3): the wizard sends `payload` to the API, which validates
// every field again and scaffolds the project through the secure generation bridge
// (see lib/generate-core.js + scripts/bot-exec-generate.sh). Kept pure so the
// mapping is unit-tested with raw node. The allowlists are imported from
// generate-core.js (the server's source of truth) so the two CANNOT drift; the
// field shapes mirror scripts/new-project.sh's flags.
import { VALID_PRESETS, VALID_DBS, VALID_LOCALES, VALID_MODULES } from './generate-core.js';

export { VALID_PRESETS, VALID_DBS, VALID_LOCALES, VALID_MODULES };

// new-project.sh: name `^[a-z][a-z0-9-]{0,38}[a-z0-9]$`; subdomain = DNS label.
// The wizard is intentionally a touch stricter than the server (letter-first, ≤40)
// so a wizard-built subdomain always also passes the server's DNS-label check.
const NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/;
const SUBDOMAIN_RE = /^[a-z]([a-z0-9-]{0,38}[a-z0-9])?$/;

function dedupe(list) {
  const seen = new Set();
  const out = [];
  for (const m of Array.isArray(list) ? list : []) {
    if (typeof m === 'string' && !seen.has(m)) { seen.add(m); out.push(m); }
  }
  return out;
}

function shellQuote(v) {
  return /^[A-Za-z0-9,_.\-]+$/.test(v) ? v : `'${String(v).replace(/'/g, `'\\''`)}'`;
}

/**
 * Build the generate payload from wizard selections.
 * @param {{preset,db,modules,subdomain,locale,name?}} sel
 * @returns {{ valid, errors, payload, projects, command }}
 */
export function buildGeneratePayload(sel = {}) {
  const preset = sel.preset;
  const db = sel.db;
  const locale = sel.locale || 'ar';
  const subdomain = (sel.subdomain || '').trim().toLowerCase();
  const name = (sel.name || subdomain || '').trim().toLowerCase();
  const modules = dedupe(sel.modules);

  const errors = [];
  if (!VALID_PRESETS.includes(preset)) errors.push(`invalid preset: ${preset}`);
  if (!VALID_DBS.includes(db)) errors.push(`invalid database: ${db}`);
  if (!VALID_LOCALES.includes(locale)) errors.push(`invalid locale: ${locale}`);
  if (!SUBDOMAIN_RE.test(subdomain) || subdomain.length < 2) errors.push('invalid subdomain (lowercase letters, digits and dashes; min 2 chars)');
  if (!NAME_RE.test(name)) errors.push('invalid project name (derived from subdomain)');
  for (const m of modules) if (!VALID_MODULES.includes(m)) errors.push(`unknown module: ${m}`);

  // The canonical payload (what a future POST /api/projects would accept, and what
  // new-project.sh receives). Stable key order for deterministic snapshots/tests.
  const payload = { name, preset, db, subdomain, locale, modules };

  const parts = [
    'scripts/new-project.sh',
    '--name', shellQuote(name || '<name>'),
    '--preset', shellQuote(preset || '<preset>'),
    '--db', shellQuote(db || '<db>'),
    '--subdomain', shellQuote(subdomain || '<subdomain>'),
    '--locale', shellQuote(locale),
  ];
  if (modules.length) parts.push('--modules', shellQuote(modules.join(',')));

  return {
    valid: errors.length === 0,
    errors,
    payload,
    projects: [payload], // the projects[] form the spec references
    command: parts.join(' '),
  };
}

/**
 * Build the confirm-dialog descriptor + the request body the wizard's review step
 * submits to POST /api/projects. PURE so the submit path is unit-tested without a
 * browser. Returns { valid:false, errors } for bad selections, otherwise the
 * exact { payload } to send plus dialog copy that NAMES what will be created.
 * @param {object} sel  wizard selections (preset/db/modules/subdomain/locale)
 * @param {'ar'|'en'} lang
 */
export function buildCreateConfirm(sel = {}, lang = 'ar') {
  const built = buildGeneratePayload(sel);
  if (!built.valid) return { valid: false, errors: built.errors };
  const p = built.payload;
  return {
    valid: true,
    payload: p,                 // the body sent to POST /api/projects
    name: p.name,
    target: `${p.subdomain}.pi.local`,
    modules: p.modules,
    title: lang === 'ar' ? `إنشاء «${p.name}»؟` : `Create “${p.name}”?`,
    message: lang === 'ar'
      ? 'سيتم توليد ملفات المشروع فقط. النشر (تشغيل الموقع) خطوة منفصلة بعد الإنشاء.'
      : 'This generates the project files only. Deploying (bringing the site up) is a separate step after creation.',
  };
}
