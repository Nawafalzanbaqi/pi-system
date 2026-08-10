#!/usr/bin/env bash
# ===========================================================================
# pi-system — SMOKE TEST harness wrapper
# ---------------------------------------------------------------------------
# scripts/smoke-test.sh is a LIVE, on-Pi check (real Docker, real network, real
# secrets) — the opposite of the offline unit suites, which mock every seam. So
# this wrapper does NOT re-run that live logic in the offline matrix. Instead it:
#
#   * OFFLINE-SAFE assertions that run everywhere (incl. this CI/dev box):
#       - the script exists and PARSES (bash -n),
#       - it still wires every required live check (static grep guards, so a
#         regression that drops a check is caught even without Docker),
#       - and — when Docker is absent — that the script SKIPs gracefully and
#         exits 0 (its "never fail off-Pi" contract, exercised for real).
#   * The LIVE run is the operator's job: ./scripts/smoke-test.sh on the Pi.
#     This wrapper only delegates to it when Docker is present AND SMOKE_LIVE=1
#     (so a routine `run.sh` stays fast and deterministic, and the offline matrix
#     stays green by SKIPping).
#
# Usage:   ./tests/smoke/run.sh            (offline: parse + wiring + skip proof)
#          SMOKE_LIVE=1 ./tests/smoke/run.sh [--url https://you.example]   (on Pi)
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run every check, then tally failures.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SMOKE="${PROJECT_ROOT}/scripts/smoke-test.sh"

# --- Colours (off when not a TTY) ------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; C=$'\033[1;36m'; O=$'\033[0m'
else
  G=''; R=''; Y=''; C=''; O=''
fi

tests_run=0; tests_failed=0; tests_skipped=0
_pass() { printf '  %s✓%s %s\n' "${G}" "${O}" "$1"; }
_fail() { printf '  %s✗%s %s\n' "${R}" "${O}" "$1"; tests_failed=$((tests_failed+1)); }
_skip() { printf '  %s~%s %s (skipped)\n' "${Y}" "${O}" "$1"; tests_skipped=$((tests_skipped+1)); }
section() { printf '\n%s== %s ==%s\n' "${C}" "$1" "${O}"; }

# grep_has NAME PATTERN  — assert the smoke script references PATTERN (a wired check).
grep_has() {
  tests_run=$((tests_run+1))
  if grep -qE "$2" "${SMOKE}"; then _pass "$1"; else _fail "$1 — '${SMOKE}' is missing /$2/"; fi
}

# ===========================================================================
section "SMOKE — script exists, parses, and is wired (offline-safe)"
# ---------------------------------------------------------------------------
tests_run=$((tests_run+1))
if [[ -f "${SMOKE}" ]]; then _pass "scripts/smoke-test.sh present"; else _fail "scripts/smoke-test.sh missing"; fi

tests_run=$((tests_run+1))
if bash -n "${SMOKE}" 2>/dev/null; then _pass "scripts/smoke-test.sh parses (bash -n)"; else _fail "scripts/smoke-test.sh has a syntax error"; fi

# Static wiring guards — each maps to one required live check in the prompt.
grep_has "wires Docker-absent SKIP (exit 0 off-Pi)"        'command -v docker'
grep_has "wires core containers (caddy/portainer/…)"        'caddy|portainer|uptime-kuma|homepage|watchtower'
grep_has "wires the 80/443-only invariant"                  '443'
grep_has "wires internal-isolation port probes"             '5432|6379|27017'
grep_has "wires the secrets audit"                          'check-secrets\.sh'
grep_has "wires the control bridge read action"             'bot-exec\.sh'
grep_has "wires the SEO/prospects engine probe"             'seo\.sh'
grep_has "wires the SSRF guard (cloud-metadata IP)"         '169\.254\.169\.254'
grep_has "wires the notifier dry-run (gated)"               'notify-telegram\.sh'
grep_has "honors TELEGRAM_NOTIFY_DRYRUN (sends nothing)"    'TELEGRAM_NOTIFY_DRYRUN=1'
grep_has "accepts an optional --url"                        '\-\-url'
grep_has "ends with a single OVERALL verdict line"          'OVERALL: (PASS|FAIL)'

# ===========================================================================
section "SMOKE — environment-gated live run"
# ---------------------------------------------------------------------------
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if [[ "${SMOKE_LIVE:-0}" == "1" ]]; then
    # On the Pi, opted in: run the REAL live smoke test and surface its verdict.
    tests_run=$((tests_run+1))
    if bash "${SMOKE}" "$@"; then _pass "live smoke-test.sh PASSED"; else _fail "live smoke-test.sh reported OVERALL: FAIL (see its table)"; fi
  else
    _skip "live smoke run (Docker present; set SMOKE_LIVE=1 to run ./scripts/smoke-test.sh here)"
  fi
else
  # No Docker here: PROVE the script's "never fail off-Pi" contract for real.
  out="$(bash "${SMOKE}" 2>&1)"; rc=$?
  tests_run=$((tests_run+1))
  if (( rc == 0 )); then _pass "smoke-test.sh exits 0 without Docker (never fails off-Pi)"; else _fail "smoke-test.sh exited ${rc} without Docker (must be 0)"; fi
  tests_run=$((tests_run+1))
  if printf '%s' "${out}" | grep -q 'SKIP' && printf '%s' "${out}" | grep -q 'OVERALL: PASS'; then
    _pass "smoke-test.sh SKIPs with a clear message off-Pi"
  else
    _fail "smoke-test.sh did not print a clean SKIP/OVERALL when Docker is absent"
  fi
  _skip "live checks (no Docker here — run ./scripts/smoke-test.sh on the Pi)"
fi

# ===========================================================================
section "Results"
# ---------------------------------------------------------------------------
printf '  %d run, %s%d failed%s, %d skipped\n' \
  "${tests_run}" "$( ((tests_failed)) && echo "${R}" || echo "${G}")" "${tests_failed}" "${O}" "${tests_skipped}"
if (( tests_failed > 0 )); then
  printf '%sTESTS FAILED%s\n' "${R}" "${O}" >&2
  exit 1
fi
printf '%sALL TESTS PASSED%s\n' "${G}" "${O}"
exit 0
