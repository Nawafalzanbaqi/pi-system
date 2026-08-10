// ===========================================================================
// pi-system Control API — CONFIG REGISTRY loader + allowlist logic (PURE)
// ---------------------------------------------------------------------------
// Loads services/control-api/config-registry.json (the allowlist) and answers
// every question the integration manager needs:
//   * is this .env key editable at all?      (isAllowedKey / getKeyDef)
//   * what shape must its value have?         (validateValue)
//   * which services restart after a change?  (restartServicesForKey)
//   * how do we present a key WITHOUT leaking secret values? (describeKey)
//
// It is deliberately dependency-free (only Node's builtin fs/url) and side-effect
// free apart from reading the JSON file once, so tests can import it with raw
// `node` and exercise the allowlist + validation without Docker/network/Keycloak.
// ===========================================================================
import { readFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

// Where to find config-registry.json, in priority order. The relative path works
// for raw `node` (tests); the fixed /app path is where the Dockerfile copies it
// in the bundled runtime image (Next does NOT trace runtime fs reads, so the
// source-relative path won't resolve there). An env override wins for custom layouts.
function registryPath() {
  const candidates = [
    process.env.CONTROL_API_REGISTRY,
    safeUrlPath('../config-registry.json'),
    '/app/config-registry.json',
  ].filter(Boolean);
  for (const p of candidates) {
    if (existsSync(p)) return p;
  }
  // Fall back to the source-relative path so the error message is meaningful.
  return safeUrlPath('../config-registry.json') || '/app/config-registry.json';
}

function safeUrlPath(rel) {
  try { return fileURLToPath(new URL(rel, import.meta.url)); } catch { return ''; }
}

let _cache = null;

// Load + cache the parsed registry. Pass an explicit path/text/object in tests.
export function loadRegistry(source) {
  if (typeof source === 'string') return normalize(JSON.parse(source));
  if (source && typeof source === 'object') return normalize(source);
  if (_cache) return _cache;
  _cache = normalize(JSON.parse(readFileSync(registryPath(), 'utf8')));
  return _cache;
}

// Build fast lookup maps; freeze so callers cannot mutate the allowlist at runtime.
function normalize(raw) {
  const integrations = Array.isArray(raw.integrations) ? raw.integrations : [];
  const byKey = new Map();
  for (const integ of integrations) {
    for (const k of integ.keys || []) {
      byKey.set(k.key, { ...k, integration: integ.id });
    }
  }
  return Object.freeze({ version: raw.version || 1, integrations, byKey });
}

// --- Allowlist predicates --------------------------------------------------
// THE core safety gate: only keys present in the manifest are touchable.
export function isAllowedKey(reg, key) {
  return typeof key === 'string' && reg.byKey.has(key);
}

export function getKeyDef(reg, key) {
  return reg.byKey.get(key) || null;
}

export function listKeys(reg) {
  return [...reg.byKey.keys()];
}

// Which services must restart for a (valid) key. Unknown key -> [] (fail safe).
export function restartServicesForKey(reg, key) {
  const def = getKeyDef(reg, key);
  return def && Array.isArray(def.restart_services) ? [...def.restart_services] : [];
}

// ===========================================================================
// VALUE VALIDATION — a basic shape check per key (see config-registry.json).
// Returns { ok: true } or { ok: false, error: "<reason>" }. NEVER echoes the
// value back in the error (we describe the rule, not the input).
// ===========================================================================
const SHAPES = {
  // BotFather token: "<digits>:<token>".
  telegram_token: /^[0-9]{6,}:[A-Za-z0-9_-]{20,}$/,
  // Comma/space/semicolon-separated numeric ids.
  digits_csv: /^[0-9]+([\s,;]+[0-9]+)*$/,
  digits: /^[0-9]+$/,
  // http(s) URL, no whitespace.
  url: /^https?:\/\/[^\s]+$/,
  // An opaque credential: printable, non-space ASCII (no quotes/backticks).
  token: /^[\x21-\x7E]+$/,
  // A free single-line string: printable ASCII incl. spaces.
  text: /^[\x20-\x7E]*$/,
};

export function validateValue(def, value) {
  if (def == null) return { ok: false, error: 'unknown key' };
  if (typeof value !== 'string') return { ok: false, error: 'value must be a string' };

  // UNIVERSAL guard, applied to EVERY key regardless of type: a value may never
  // contain a newline or carriage return. This is what stops a written value
  // from injecting an extra line (or a second KEY=...) into .env.
  if (/[\r\n]/.test(value)) return { ok: false, error: 'value must not contain line breaks' };

  const empty = value.length === 0;
  if (empty) {
    return def.allow_empty
      ? { ok: true }
      : { ok: false, error: 'value must not be empty for this key' };
  }

  // Hard upper bound — defensive against absurd payloads.
  if (value.length > 4096) return { ok: false, error: 'value is too long (max 4096 chars)' };

  const rule = def.validate || 'text';
  if (rule === 'enum') {
    const allowed = Array.isArray(def.enum) ? def.enum : [];
    return allowed.includes(value)
      ? { ok: true }
      : { ok: false, error: `value must be one of: ${allowed.join(', ')}` };
  }
  const re = SHAPES[rule] || SHAPES.text;
  return re.test(value)
    ? { ok: true }
    : { ok: false, error: `value does not match the expected shape (${rule})` };
}

// ===========================================================================
// PRESENTATION — describe a key for GET /api/integrations WITHOUT leaking a
// secret value. For a SECRET we return ONLY set/empty + a fixed mask string;
// the actual characters are NEVER included. For a non-secret we may include the
// value (it is, by definition, not sensitive).
// ===========================================================================
const MASK = '••••••••';

export function describeKey(def, rawValue) {
  const value = typeof rawValue === 'string' ? rawValue : '';
  const isSet = value.trim().length > 0;
  const base = {
    key: def.key,
    label: def.label,
    secret: !!def.secret,
    set: isSet,
    restart_services: Array.isArray(def.restart_services) ? def.restart_services : [],
  };
  if (def.note) base.note = def.note;
  if (def.validate === 'enum' && Array.isArray(def.enum)) base.enum = def.enum;
  if (def.secret) {
    // SECRET: indicator only — never the value.
    base.masked = isSet ? MASK : '';
  } else {
    // Non-secret: safe to surface the actual value.
    base.value = value;
  }
  return base;
}

export const _MASK = MASK;
