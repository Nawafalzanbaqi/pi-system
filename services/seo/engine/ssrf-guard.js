// pi-system SEO engine — SSRF guard: is this URL/host safe to fetch?
// ===========================================================================
// WHY this exists: the probe (probe.js) and, through it, the prospects organizer
// (services/prospects) fetch URLs the OPERATOR types in. On a Pi 5 that sits on
// a home/LAN behind Docker, an attacker-influenced or fat-fingered URL could be
// turned into a Server-Side Request Forgery: http://169.254.169.254/ (cloud
// metadata), http://10.0.0.x/ (LAN box), http://postgres:5432/ (a sibling Docker
// service reachable by its compose name), or http://localhost/ (the host itself).
// This module is the single chokepoint that decides whether a target is allowed
// BEFORE any fetch happens, and re-checks AFTER DNS resolution so a public name
// that resolves to a private IP (classic DNS-rebinding) is still rejected.
//
// Design rules (mirroring the rest of the engine):
//   * PURE + DEPENDENCY-FREE. Every classifier (ipv4ToInt, isBlockedIPv4,
//     isBlockedIPv6, isLocalHostname, classifyHost, classifyUrl) is deterministic
//     and does NO I/O, so the whole policy is unit-testable with zero network.
//   * The ONLY impure function is assertUrlAllowed(), and even its single
//     side-effect (DNS resolution) is injectable via deps.resolve for tests.
//   * FAIL CLOSED. Anything we can't confidently prove is public is blocked.
//   * NON-LEAKY errors. A blocked fetch never echoes back the internal IP a name
//     resolved to — that would itself be an information leak.
//
// Escape hatch: an operator who deliberately wants to audit a box on their own
// LAN can set PROSPECTS_PROBE_ALLOW_PRIVATE=1 (see allowPrivate). That opt-in
// relaxes ONLY the address/hostname checks — it never permits non-http(s)
// schemes or URLs carrying credentials, which are always refused.
// ===========================================================================

// ---------------------------------------------------------------------------
// IPv4 ----------------------------------------------------------------------
// ---------------------------------------------------------------------------

// ipv4ToInt('127.0.0.1') -> 2130706433 ; returns null for anything that is not a
// CANONICAL dotted-quad. We are deliberately strict: 4 decimal octets, each 0..255,
// no leading zeros. Non-canonical forms (octal "0177.0.0.1", short "127.1", a bare
// integer "2130706433", hex) are a well-known SSRF bypass class — the OS resolver
// may read "0177" as octal 127 while a naive parser reads decimal 177. By refusing
// to parse them here, classifyHost() can fail such inputs closed instead of guessing.
export function ipv4ToInt(s) {
  if (typeof s !== 'string') return null;
  const parts = s.split('.');
  if (parts.length !== 4) return null;
  let n = 0;
  for (const p of parts) {
    if (!/^\d{1,3}$/.test(p)) return null;
    if (p.length > 1 && p[0] === '0') return null; // reject leading zeros (octal bypass)
    const v = Number(p);
    if (v > 255) return null;
    n = n * 256 + v;
  }
  return n >>> 0;
}

// Private / reserved IPv4 ranges we refuse to fetch. Listed as [base, prefixBits]
// and precompiled to [baseInt, maskInt] once below.
const V4_BLOCKS = [
  ['0.0.0.0', 8],        // "this" network / 0.0.0.0
  ['10.0.0.0', 8],       // RFC1918 private
  ['100.64.0.0', 10],    // RFC6598 CGNAT shared address space
  ['127.0.0.0', 8],      // loopback
  ['169.254.0.0', 16],   // link-local — includes 169.254.169.254 cloud metadata
  ['172.16.0.0', 12],    // RFC1918 private
  ['192.0.0.0', 24],     // IETF protocol assignments
  ['192.0.2.0', 24],     // TEST-NET-1 (documentation)
  ['192.168.0.0', 16],   // RFC1918 private
  ['198.18.0.0', 15],    // benchmarking
  ['198.51.100.0', 24],  // TEST-NET-2 (documentation)
  ['203.0.113.0', 24],   // TEST-NET-3 (documentation)
  ['224.0.0.0', 4],      // multicast
  ['240.0.0.0', 4],      // reserved / future use (includes 255.255.255.255 broadcast)
];

function v4Mask(prefix) {
  return prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0;
}

const V4_BLOCKS_INT = V4_BLOCKS.map(([base, prefix]) => {
  const mask = v4Mask(prefix);
  return [(ipv4ToInt(base) & mask) >>> 0, mask];
});

// isBlockedIPv4 — accepts either a dotted-quad string or a 32-bit integer.
// A string that is not a canonical IPv4 returns false here (it is NOT a valid IPv4,
// so it is not an IPv4 in blocked space); classifyHost is what decides such inputs.
export function isBlockedIPv4(ip) {
  const n = typeof ip === 'number' ? ip >>> 0 : ipv4ToInt(ip);
  if (n === null) return false;
  for (const [base, mask] of V4_BLOCKS_INT) {
    if (((n & mask) >>> 0) === base) return true;
  }
  return false;
}

// ---------------------------------------------------------------------------
// IPv6 ----------------------------------------------------------------------
// ---------------------------------------------------------------------------

// parseIPv6('fe80::1') -> Uint8Array(16) ; returns null if not a valid IPv6.
// Handles '::' zero-compression (at most one) and an embedded IPv4 tail
// (e.g. ::ffff:192.168.0.1), which it folds into two 16-bit groups first.
function parseIPv6(input) {
  let s = String(input || '').trim().toLowerCase();
  s = s.split('%')[0]; // drop a zone id like %eth0
  if (s.startsWith('[') && s.endsWith(']')) s = s.slice(1, -1);
  if (!s || !s.includes(':')) return null;
  if ((s.match(/::/g) || []).length > 1) return null; // only one '::' allowed

  // Fold a trailing dotted IPv4 (::ffff:1.2.3.4) into two hex groups.
  const v4tail = /^(.*:)(\d{1,3}(?:\.\d{1,3}){3})$/.exec(s);
  if (v4tail) {
    const v4 = ipv4ToInt(v4tail[2]);
    if (v4 === null) return null;
    const hi = ((v4 >>> 16) & 0xffff).toString(16);
    const lo = (v4 & 0xffff).toString(16);
    s = `${v4tail[1]}${hi}:${lo}`;
  }

  const halves = s.split('::');
  if (halves.length > 2) return null;
  const head = halves[0] === '' ? [] : halves[0].split(':');
  const tail = halves.length === 2 ? (halves[1] === '' ? [] : halves[1].split(':')) : null;

  let groups;
  if (tail === null) {
    groups = head; // no '::' — must be a full 8-group address
  } else {
    const missing = 8 - (head.length + tail.length);
    if (missing < 1) return null; // '::' must stand for at least one zero group
    groups = [...head, ...Array(missing).fill('0'), ...tail];
  }
  if (groups.length !== 8) return null;

  const bytes = new Uint8Array(16);
  for (let i = 0; i < 8; i += 1) {
    const g = groups[i];
    if (!/^[0-9a-f]{1,4}$/.test(g)) return null;
    const v = parseInt(g, 16);
    bytes[i * 2] = (v >> 8) & 0xff;
    bytes[i * 2 + 1] = v & 0xff;
  }
  return bytes;
}

// isBlockedIPv6 — a malformed IPv6 string returns false (not a valid IPv6 in blocked
// space); classifyHost decides such inputs. IPv4-mapped and the deprecated
// IPv4-compatible forms are delegated to isBlockedIPv4 so ::ffff:127.0.0.1 is blocked.
export function isBlockedIPv6(input) {
  const b = parseIPv6(input);
  if (!b) return false;

  const allZeroUpTo = (n) => {
    for (let i = 0; i < n; i += 1) if (b[i] !== 0) return false;
    return true;
  };
  const embeddedV4 = () => ((b[12] << 24) | (b[13] << 16) | (b[14] << 8) | b[15]) >>> 0;

  if (b.every((x) => x === 0)) return true;                 // :: unspecified
  if (allZeroUpTo(15) && b[15] === 1) return true;          // ::1 loopback
  if (allZeroUpTo(10) && b[10] === 0xff && b[11] === 0xff) return isBlockedIPv4(embeddedV4()); // ::ffff:0:0/96 IPv4-mapped
  if (allZeroUpTo(12)) return isBlockedIPv4(embeddedV4());  // ::/96 IPv4-compatible (deprecated)
  if ((b[0] & 0xfe) === 0xfc) return true;                  // fc00::/7 unique-local
  if (b[0] === 0xfe && (b[1] & 0xc0) === 0x80) return true; // fe80::/10 link-local
  if (b[0] === 0xff) return true;                           // ff00::/8 multicast
  return false;
}

// ---------------------------------------------------------------------------
// Hostnames -----------------------------------------------------------------
// ---------------------------------------------------------------------------

// Normalize a host the way the rest of this module expects: lowercase, no
// surrounding [] for IPv6, no %zone, no trailing FQDN dot.
function normalizeHost(h) {
  let s = String(h || '').trim().toLowerCase();
  if (s.startsWith('[') && s.endsWith(']')) s = s.slice(1, -1);
  s = s.split('%')[0];
  if (s.length > 1 && s.endsWith('.')) s = s.slice(0, -1);
  return s;
}

// isLocalHostname — name-based (NOT IP) internal targets we refuse:
//   localhost, *.localhost, *.local (mDNS), *.internal, and any single-label host
//   with no dot at all (e.g. "postgres", "redis" — Docker compose service names that
//   resolve on the container network). IP literals return false here; classifyHost
//   routes those to the numeric classifiers instead.
export function isLocalHostname(host) {
  const h = normalizeHost(host);
  if (!h) return false;
  if (h.includes(':')) return false;     // IPv6 literal — not a name
  if (/^[0-9.]+$/.test(h)) return false; // IPv4 / numeric literal — not a name
  if (h === 'localhost') return true;
  if (h.endsWith('.localhost')) return true;
  if (h.endsWith('.local')) return true;
  if (h.endsWith('.internal')) return true;
  if (!h.includes('.')) return true;     // single-label → Docker service name
  return false;
}

const blockedHost = (kind, host, reason) => ({ host, kind, blocked: true, reason });
const allowedHost = (kind, host) => ({ host, kind, blocked: false, reason: null });

// classifyHost(host) -> { host, kind, blocked, reason }
//   kind ∈ 'ipv4' | 'ipv6' | 'hostname'. Pure; the central decision used by both
//   classifyUrl and assertUrlAllowed (the latter also re-runs it on resolved IPs).
export function classifyHost(host) {
  const h = normalizeHost(host);
  if (!h) return blockedHost('hostname', h, 'empty host');

  // IPv6 literal (anything with a colon).
  if (h.includes(':')) {
    if (!parseIPv6(h)) return blockedHost('ipv6', h, 'malformed IPv6 address');
    return isBlockedIPv6(h)
      ? blockedHost('ipv6', h, 'private/reserved IPv6 address')
      : allowedHost('ipv6', h);
  }

  // All digits-and-dots → an IPv4 address attempt. A non-canonical numeric form
  // (octal, short, integer, overflow) is ambiguous vs. the OS resolver — fail closed.
  if (/^[0-9.]+$/.test(h)) {
    const n = ipv4ToInt(h);
    if (n === null) return blockedHost('ipv4', h, 'ambiguous or non-canonical numeric IPv4 form');
    return isBlockedIPv4(n)
      ? blockedHost('ipv4', h, 'private/reserved IPv4 address')
      : allowedHost('ipv4', h);
  }

  // Otherwise a DNS hostname.
  return isLocalHostname(h)
    ? blockedHost('hostname', h, 'internal/non-public hostname')
    : allowedHost('hostname', h);
}

// classifyUrl(url) -> { url, host, kind, blocked, reason, scheme }
//   A single pure verdict over a whole URL: the scheme must be http/https and the
//   URL must not embed credentials (user:pass@host — an exfiltration/confusion risk),
//   then the host is classified. Never throws; returns blocked:true with a reason.
export function classifyUrl(url) {
  let parsed;
  try {
    parsed = new URL(String(url));
  } catch {
    return { url: String(url), host: null, kind: 'url', blocked: true, reason: 'invalid URL', scheme: null };
  }
  const scheme = parsed.protocol.replace(/:$/, '').toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') {
    return { url: parsed.href, host: parsed.hostname || null, kind: 'url', blocked: true, reason: `unsupported URL scheme '${scheme}'`, scheme };
  }
  if (parsed.username || parsed.password) {
    return { url: parsed.href, host: parsed.hostname || null, kind: 'url', blocked: true, reason: 'credentials in URL are not allowed', scheme };
  }
  const c = classifyHost(normalizeHost(parsed.hostname));
  return { url: parsed.href, host: c.host, kind: c.kind, blocked: c.blocked, reason: c.reason, scheme };
}

// ---------------------------------------------------------------------------
// Opt-in escape hatch + the impure assertion -------------------------------
// ---------------------------------------------------------------------------

// allowPrivate(env) — operator opt-in to audit private/LAN targets on purpose.
// Reads PROSPECTS_PROBE_ALLOW_PRIVATE; accepts 1/true/yes/on. Relaxes only the
// address & hostname checks — never schemes or credentials.
export function allowPrivate(env) {
  const e = env || (typeof process !== 'undefined' ? process.env : {}) || {};
  const v = String(e.PROSPECTS_PROBE_ALLOW_PRIVATE || '').trim().toLowerCase();
  return v === '1' || v === 'true' || v === 'yes' || v === 'on';
}

function ssrfError(message) {
  const err = new Error(`SSRF guard: ${message}`);
  err.code = 'SSRF_BLOCKED';
  err.blocked = true;
  return err;
}

// Default DNS resolver: node:dns lookup with all addresses, in resolver order.
// Imported lazily so the pure classifiers above never pull in node:dns and the
// module stays loadable (and testable) outside Node. Tests inject deps.resolve.
async function defaultResolve(host) {
  const dns = await import('node:dns');
  const records = await dns.promises.lookup(host, { all: true, verbatim: true });
  return records.map((r) => r.address);
}

// assertUrlAllowed(url, deps) — the gate. Resolves to { url, host, addresses } when
// safe, otherwise THROWS a clear, non-leaky SSRF_BLOCKED Error. deps:
//   deps.env      environment object (default process.env) for allowPrivate.
//   deps.resolve  async (host) => string[]  (default: node:dns lookup all).
// Policy (scheme/credentials/parse) is enforced FIRST and is never bypassable.
// Then the host is classified; then it is resolved and EVERY resulting IP is
// re-classified, so a public name pointing at a private IP (DNS rebinding) is
// still refused. allowPrivate relaxes the address checks but not the policy ones.
export async function assertUrlAllowed(url, deps = {}) {
  const env = deps.env || (typeof process !== 'undefined' ? process.env : {});
  const resolve = typeof deps.resolve === 'function' ? deps.resolve : defaultResolve;
  const bypass = allowPrivate(env);

  // --- Policy: parse, scheme, credentials. Never bypassable. ---------------
  let parsed;
  try {
    parsed = new URL(String(url));
  } catch {
    throw ssrfError('invalid URL');
  }
  const scheme = parsed.protocol.replace(/:$/, '').toLowerCase();
  if (scheme !== 'http' && scheme !== 'https') {
    throw ssrfError(`unsupported URL scheme '${scheme}' (only http/https allowed)`);
  }
  if (parsed.username || parsed.password) {
    throw ssrfError('URLs with embedded credentials are not allowed');
  }
  const host = normalizeHost(parsed.hostname);
  if (!host) throw ssrfError('URL has no host');

  // --- Literal / name classification. Bypassable via allowPrivate. ---------
  const cls = classifyHost(host);
  if (cls.blocked && !bypass) {
    throw ssrfError(`refusing to fetch ${cls.reason} (${host})`);
  }

  // --- Resolve + re-check every address (DNS-rebinding defense). ------------
  let addresses;
  if (cls.kind === 'ipv4' || cls.kind === 'ipv6') {
    addresses = [host]; // a literal address resolves to itself
  } else {
    try {
      addresses = await resolve(host);
    } catch {
      throw ssrfError(`could not resolve host '${host}'`);
    }
    if (!Array.isArray(addresses) || addresses.length === 0) {
      throw ssrfError(`host '${host}' did not resolve to any address`);
    }
    if (!bypass) {
      for (const addr of addresses) {
        if (classifyHost(addr).blocked) {
          // Non-leaky: name the host the caller gave, never the internal IP behind it.
          throw ssrfError(`host '${host}' resolves into blocked/private address space`);
        }
      }
    }
  }

  return { url: parsed.href, host, addresses };
}
