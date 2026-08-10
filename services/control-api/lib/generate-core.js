// ===========================================================================
// pi-system Control API — GENERATE CORE (PURE — the constrained creation path)
// ---------------------------------------------------------------------------
// The API NEVER runs an arbitrary host command and NEVER silently overwrites a
// project. Project creation maps to the ONE fixed generation action,
// `create-project`, whose every field is validated HERE before it is handed to
// the transport (lib/bridge.js -> scripts/bot-exec-generate.sh -> new-project.sh).
//
// This module is PURE: it validates the wizard payload field-by-field against
// allowlists / strict patterns and, on success, returns the bot-exec-generate
// ARGV as an ARRAY (e.g. ["create-project","--name","noor", …]) — NEVER a
// concatenated shell string, so the transport spawns argv directly and no shell
// ever interprets a value. It also NEVER emits `--force`: there is no code path
// that adds it, so the API can never clobber an existing project.
//
// IMPORTANT — keep in sync with scripts/lib/bot-lib.sh (the bridge re-validates
// every field there: defence in depth) AND with components/catalog.js / the
// wizard. tests/control-api cross-checks these JS allowlists against bot-lib.sh,
// and tests/control-ui cross-checks the wizard's, so they cannot silently drift.
// ===========================================================================

// Sector presets new-project.sh ships (each declares base/db/locale/modules).
export const VALID_PRESETS = Object.freeze(['clinic', 'ecommerce', 'company-site', 'real-estate']);
// Base shapes a project can be built from directly (preset XOR base).
export const VALID_BASES = Object.freeze(['dotnet-api', 'nextjs-app', 'fullstack']);
// Database engines.
export const VALID_DBS = Object.freeze(['postgres', 'mysql', 'mongo', 'none']);
// Default locales (ar => RTL).
export const VALID_LOCALES = Object.freeze(['ar', 'en']);
// Implemented, panel-exposed feature modules (the curated product set; the dev
// `hello-module` is deliberately excluded — it is never offered through the panel).
export const VALID_MODULES = Object.freeze([
  'i18n-bilingual', 'content-admin', 'bookings', 'auth-sso',
  'whatsapp-integration', 'local-payments', 'web-analytics', 'seo-toolkit',
]);

// Identical to new-project.sh / bot-lib.sh: name shape + DNS-label subdomain.
const NAME_RE = /^[a-z][a-z0-9-]{0,38}[a-z0-9]$/;
const SUBDOMAIN_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

export function isValidProjectName(n) { return typeof n === 'string' && NAME_RE.test(n); }
export function isValidPreset(p) { return VALID_PRESETS.includes(p); }
export function isValidBase(b) { return VALID_BASES.includes(b); }
export function isValidDb(d) { return VALID_DBS.includes(d); }
export function isValidLocale(l) { return VALID_LOCALES.includes(l); }
export function isValidModule(m) { return VALID_MODULES.includes(m); }
export function isValidSubdomain(s) { return typeof s === 'string' && SUBDOMAIN_RE.test(s); }

const bad = (error) => ({ ok: false, status: 400, error });

// Dedupe a modules list (order-preserving). Returns { ok:false } if it is not an
// array of strings — so a malformed list is REJECTED, never coerced.
function normalizeModules(list) {
  if (list == null) return { ok: true, modules: [] };
  if (!Array.isArray(list)) return { ok: false };
  const seen = new Set();
  const out = [];
  for (const m of list) {
    if (typeof m !== 'string') return { ok: false };
    if (!seen.has(m)) { seen.add(m); out.push(m); }
  }
  return { ok: true, modules: out };
}

/**
 * Validate a create payload and build the bot-exec-generate ARGV.
 *   -> { ok: true, argv: ["create-project", "--name", …], normalized: {…} }
 *   -> { ok: false, status: 400, error }
 * Every field is rejected (never sanitized) if it is not in the allowlist /
 * pattern. The returned argv is an ARRAY and NEVER contains "--force".
 * @param {{name,preset?,base?,modules?,db,subdomain?,locale?}} payload
 */
export function buildGenerateArgs(payload) {
  if (payload == null || typeof payload !== 'object') return bad('payload must be a JSON object');

  const name = payload.name;
  const hasPreset = payload.preset != null && payload.preset !== '';
  const hasBase = payload.base != null && payload.base !== '';
  const db = payload.db;
  const locale = payload.locale == null || payload.locale === '' ? 'ar' : payload.locale;
  const subdomain = payload.subdomain == null || payload.subdomain === '' ? name : payload.subdomain;

  const mods = normalizeModules(payload.modules);
  if (!mods.ok) return bad('modules must be an array of module names');
  const modules = mods.modules;

  if (!isValidProjectName(name)) return bad(`invalid project name '${name}'`);
  // Exactly one of preset|base (a preset declares a base; a base is explicit).
  if (hasPreset && hasBase) return bad('provide exactly one of preset or base (not both)');
  if (!hasPreset && !hasBase) return bad('provide a preset or a base shape');
  if (hasPreset && !isValidPreset(payload.preset)) return bad(`unknown preset '${payload.preset}'`);
  if (hasBase && !isValidBase(payload.base)) return bad(`unknown base shape '${payload.base}'`);
  if (!isValidDb(db)) return bad(`invalid database engine '${db}'`);
  if (!isValidLocale(locale)) return bad(`invalid locale '${locale}'`);
  if (!isValidSubdomain(subdomain)) return bad(`invalid subdomain '${subdomain}'`);
  for (const m of modules) if (!isValidModule(m)) return bad(`unknown module '${m}'`);

  // Build the ARGV array — never a string, never with --force.
  const argv = ['create-project', '--name', name];
  if (hasPreset) argv.push('--preset', String(payload.preset));
  else argv.push('--base', String(payload.base));
  argv.push('--db', String(db), '--subdomain', String(subdomain), '--locale', String(locale));
  if (modules.length) argv.push('--modules', modules.join(','));

  return {
    ok: true,
    argv,
    normalized: {
      name,
      preset: hasPreset ? String(payload.preset) : null,
      base: hasBase ? String(payload.base) : null,
      db: String(db),
      subdomain: String(subdomain),
      locale: String(locale),
      modules,
    },
  };
}
