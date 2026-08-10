// integrations-view.js — PURE helpers that ENFORCE the secret write-only
// invariant at the view layer. The API already guarantees it never returns a
// secret value; these make the UI code path provably honour it too, and give the
// tests a single function to assert against.
export function isSecretKey(k) { return !!(k && k.secret); }

// The ONLY value the UI may EVER display for a config key. For a secret this is
// ALWAYS null — even if a value somehow appeared on the object, we refuse to show
// it. For a non-secret the (non-sensitive) value may be shown.
export function displayableKeyValue(k) {
  if (!k || k.secret) return null;
  return typeof k.value === 'string' ? k.value : null;
}

// Audit a GET /api/integrations payload (or any fixture) for leaks: a secret key
// that carries a real value, or a "masked" indicator made of anything other than
// bullet/space characters. Returns the offending key names ([] when clean).
export function secretValueLeaks(integrations) {
  const leaks = [];
  for (const g of integrations || []) {
    for (const k of g.keys || []) {
      if (!k || !k.secret) continue;
      if ('value' in k && k.value) leaks.push(k.key);
      if (typeof k.masked === 'string' && /[^•\s]/.test(k.masked)) leaks.push(k.key);
    }
  }
  return leaks;
}
