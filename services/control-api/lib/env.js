// ===========================================================================
// pi-system Control API — .env TEXT operations (PURE, string in / string out)
// ---------------------------------------------------------------------------
// The deterministic core of safe .env handling, modelled on the existing secrets
// tooling conventions:
//   * getEnvValue   mirrors scripts/check-secrets.sh get_value — reads a value
//                   WITHOUT ever executing the file (an .env is never `source`d),
//                   strips a trailing CR + surrounding quotes.
//   * setEnvValue   mirrors scripts/generate-secrets.sh set_secret — replaces an
//                   existing "KEY=" line IN PLACE (so comments, ordering and
//                   every other line are preserved) and only appends when the key
//                   is genuinely absent.
//
// These functions take and return STRINGS, so they are trivially testable with
// no filesystem at all. The actual read/backup/atomic-write lives in env-writer.js
// (a thin fs SEAM that calls these). NOTHING here logs or returns a secret on its
// own — callers decide what to surface.
// ===========================================================================

// Parse "KEY=value" lines into a Map (last one wins, like the shell would).
// Comment and blank lines are ignored. No interpolation, no eval.
export function parseEnvText(text) {
  const map = new Map();
  for (const rawLine of String(text ?? '').split('\n')) {
    const line = rawLine.replace(/\r$/, '');
    const t = line.trimStart();
    if (t === '' || t.startsWith('#')) continue;
    const eq = line.indexOf('=');
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) continue;
    map.set(key, stripValue(line.slice(eq + 1)));
  }
  return map;
}

// Strip trailing CR, edge whitespace and ONE pair of matching surrounding quotes.
function stripValue(raw) {
  let v = String(raw).replace(/\r$/, '');
  v = v.trim();
  if (v.length >= 2 && ((v[0] === '"' && v.endsWith('"')) || (v[0] === "'" && v.endsWith("'")))) {
    v = v.slice(1, -1);
  }
  return v;
}

// Read a single key's value (or "" if absent). Last assignment wins.
export function getEnvValue(text, key) {
  const map = parseEnvText(text);
  return map.has(key) ? map.get(key) : '';
}

// Return the full .env TEXT with `key` set to `value`, preserving everything
// else. Replaces the FIRST matching "KEY=" line in place; appends a new line
// only if the key is absent. The caller must have validated `value` already
// (env-writer refuses anything containing a newline — see registry.validateValue).
export function setEnvValue(text, key, value) {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) {
    throw new Error('refusing to write an invalid env key name');
  }
  if (/[\r\n]/.test(value)) {
    // Defence in depth — env-writer/registry already block this.
    throw new Error('refusing to write a value containing a line break');
  }
  const src = String(text ?? '');
  const hadTrailingNewline = src.endsWith('\n');
  const lines = src.split('\n');
  // split on a trailing newline leaves a final "" element; track and drop it.
  if (hadTrailingNewline) lines.pop();

  const re = new RegExp(`^(\\s*)${escapeRe(key)}=`);
  let replaced = false;
  for (let i = 0; i < lines.length; i++) {
    const stripped = lines[i].replace(/\r$/, '');
    if (re.test(stripped)) {
      const indent = (stripped.match(/^(\s*)/) || ['', ''])[1];
      lines[i] = `${indent}${key}=${value}`;
      replaced = true;
      break;
    }
  }
  if (!replaced) lines.push(`${key}=${value}`);

  let out = lines.join('\n');
  if (hadTrailingNewline || !replaced) out += '\n';
  return out;
}

function escapeRe(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

// ===========================================================================
// INTEGRATION SUMMARY — build the GET /api/integrations payload from the
// registry + the current .env TEXT, WITHOUT ever exposing a secret value.
// (describeKey in registry.js enforces the masking; this only wires it up.)
// ===========================================================================
export function summarizeIntegrations(reg, envText, describeKey) {
  const map = parseEnvText(envText);
  return reg.integrations.map((integ) => ({
    id: integ.id,
    label: integ.label,
    description: integ.description || '',
    keys: (integ.keys || []).map((def) => describeKey(def, map.get(def.key) ?? '')),
  }));
}
