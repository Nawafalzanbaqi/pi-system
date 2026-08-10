#!/usr/bin/env node
// pi-system SEO engine — STAGE-1 SSRF check CLI (operator-pasted URLs).
// ===========================================================================
// The audited bot bridge (scripts/bot-exec.sh) runs this BEFORE spawning any
// audit container, so a URL that points at an internal host / a non-http(s)
// scheme / a credential-bearing URL is refused at the boundary — never reaches
// the real probe. Pure, dependency-free, NO DNS (so it is offline-testable AND
// it cannot stall on a hostile DNS server): it uses classifyUrl from the SAME
// SSRF guard module the engine uses, which catches the operator-pasted
// mistakes that matter on a Pi sharing a network with internal services:
//   * non-http(s) scheme (file://, ftp://, javascript:, …)
//   * credentials in the URL (http://user:pass@…)
//   * literal internal IPv4/IPv6 (127.0.0.1, 10.x, fc00::, ::1, …)
//   * non-canonical IPv4 forms (octal/short/integer — classic bypass shapes)
//   * internal hostnames (localhost / *.internal / *.local / single-label
//     Docker service names — postgres, redis, …)
//
// The DNS-rebinding-aware check (a public name that resolves to a private IP)
// is enforced LATER by probeUrl's full assertUrlAllowed inside the audit
// container — defence in depth. Refusing those obvious shapes here keeps the
// dry-run testable + the boundary fast.
//
// USAGE
//   node services/seo/engine/ssrf-check.js <url>
//
// URL is read from argv[2] — a SINGLE argv element. NEVER interpolated into a
// shell string, NEVER eval'd; the bridge invokes this via execFile-style argv.
//
// EXIT CODES
//   0  the URL is acceptable for the next stage (the engine still re-checks).
//   2  refused. The reason is written to stderr (non-leaky — never echoes the
//      resolved IP a name might point at, which itself would be an info leak).
// ===========================================================================

import { classifyUrl } from './ssrf-guard.js';

const url = process.argv[2];
if (!url || typeof url !== 'string' || !url.length) {
  process.stderr.write('ssrf-check: missing url argv\n');
  process.exit(2);
}

const v = classifyUrl(url);
if (v.blocked) {
  // Non-leaky: name only the host the operator gave (NOT any resolved IP).
  const host = v.host || url;
  process.stderr.write(`SSRF guard: refusing ${v.reason} (${host})\n`);
  process.exit(2);
}
process.exit(0);
