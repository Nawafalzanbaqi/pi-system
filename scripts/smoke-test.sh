#!/usr/bin/env bash
# ===========================================================================
# pi-system — LIVE post-install SMOKE TEST  (operator-run, ON the Pi)
# ---------------------------------------------------------------------------
# The single command you run AFTER installing + bringing the stack up, to prove
# the REAL system works end to end. This is deliberately DISTINCT from the
# offline unit suites under tests/ (which mock every seam and never touch Docker
# or the network): THIS one exercises the live containers, the live network
# boundary, the live secrets, the live control-bridge and the live SEO/SSRF
# engine on the actual hardware. It prints a clear PASS/FAIL table with a
# remediation hint under every problem, then one final OVERALL line.
#
# It is SAFE to run repeatedly (idempotent) and read-only where it can be: the
# only writes are to the platform's OWN data (a throwaway SEO audit under
# data/seo/{audits,latest}/smoke-*, and the bridge's own audit log) — NEVER to a
# client's project or database.
#
# WHAT IT CHECKS (each maps to a go-live invariant):
#   1. Environment      Docker reachable? If not (a dev box), SKIP and exit 0 —
#                       this test only means something on a Pi with the stack up.
#   2. Core liveness    the core containers are running (caddy, portainer,
#                       uptime-kuma, homepage, watchtower); Caddy is listening on
#                       80 + 443; and ONLY those host ports are published anywhere
#                       (the 80/443-only invariant, re-asserted against live state).
#   3. Internal isolation  internal-only services (postgres/redis/n8n/…and the
#                       admin UIs) are NOT reachable from the host — proof the
#                       network boundary holds and nothing leaked a host port.
#   4. Secrets          scripts/check-secrets.sh exits 0 (all 11 keys filled,
#                       nothing critical-missing).
#   5. Bridge health    the audited control-bridge (the same scripts/bot-exec.sh
#                       the Control API reaches over SSH) answers a READ-ONLY
#                       action successfully.
#   6. Engine + SSRF    the SEO/prospects engine produces a real audit object
#                       (all 5 category scores + a verdict) for an owned --url,
#                       AND the SSRF guard REFUSES http://169.254.169.254/ (the
#                       cloud-metadata IP) with no fetch — the live safety boundary.
#   7. Notifier         scripts/notify-telegram.sh is wired and GATED: a dry-run
#                       sends nothing and never prints the token.
#
# USAGE
#   ./scripts/smoke-test.sh [--url https://a-site-you-own.example] [-h|--help]
#
#     --url URL   The SAFE, PUBLIC site you OWN to probe in check 6 (the engine
#                 fetches it outbound). Defaults to https://example.com (the IANA
#                 reserved example domain) so the test runs with no setup — but
#                 prefer passing your own site so the audit is meaningful.
#
# Exit code: 0 when every check PASSes (or the whole run SKIPs off-Pi), 1 if any
# check FAILs. Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -uo pipefail   # deliberately NOT -e: run EVERY check, then tally + verdict.

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SCRIPTS="${SCRIPT_DIR}"
cd "${PROJECT_ROOT}"

# --- Colours (off when not a TTY, or NO_COLOR set) -------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'; C_RED=$'\033[0;31m'
  C_CYAN=$'\033[1;36m';  C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_GREEN=''; C_YELLOW=''; C_RED=''; C_CYAN=''; C_DIM=''; C_BOLD=''; C_OFF=''
fi

usage() { sed -n '2,46p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- Parse arguments -------------------------------------------------------
URL="https://example.com"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)   [[ $# -ge 2 ]] || { printf 'error: --url requires a value.\n' >&2; exit 2; }; URL="$2"; shift 2 ;;
    --url=*) URL="${1#*=}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown argument: %q\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

# --- Result table machinery ------------------------------------------------
pass_n=0; warn_n=0; fail_n=0; skip_n=0
vcol() {
  case "$1" in
    PASS) printf '%sPASS%s' "${C_GREEN}"  "${C_OFF}" ;;
    FAIL) printf '%sFAIL%s' "${C_RED}"    "${C_OFF}" ;;
    WARN) printf '%sWARN%s' "${C_YELLOW}" "${C_OFF}" ;;
    SKIP) printf '%sSKIP%s' "${C_DIM}"    "${C_OFF}" ;;
    *)    printf '%s' "$1" ;;
  esac
}
# record STATUS LABEL DETAIL [HINT]  — count, print the row, and (on WARN/FAIL)
# print the remediation hint indented beneath it.
record() {
  local st="$1" label="$2" detail="${3:-}" hint="${4:-}"
  case "${st}" in PASS) pass_n=$((pass_n+1));; WARN) warn_n=$((warn_n+1));;
                  FAIL) fail_n=$((fail_n+1));; SKIP) skip_n=$((skip_n+1));; esac
  printf '  [%s] %-34s %s\n' "$(vcol "${st}")" "${label}" "${detail}"
  if [[ -n "${hint}" && ( "${st}" == "FAIL" || "${st}" == "WARN" ) ]]; then
    printf '         %s↳ %s%s\n' "${C_DIM}" "${hint}" "${C_OFF}"
  fi
}
note()    { printf '         %s%s%s\n' "${C_DIM}" "$*" "${C_OFF}"; }
section() { printf '\n%s== %s ==%s\n' "${C_CYAN}" "$1" "${C_OFF}"; }

# Read a value from .env WITHOUT sourcing it (never execute the env file).
env_get() {
  local key="$1" line val
  [[ -f "${PROJECT_ROOT}/.env" ]] || { printf ''; return 0; }
  line="$(grep -E "^[[:space:]]*${key}=" "${PROJECT_ROOT}/.env" 2>/dev/null | tail -n1 || true)"
  val="${line#*=}"; val="${val%$'\r'}"
  val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
  if   [[ "${val}" == \"*\" && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"
  elif [[ "${val}" == \'*\' && ${#val} -ge 2 ]]; then val="${val:1:${#val}-2}"; fi
  printf '%s' "${val}"
}

# A TCP connect to 127.0.0.1:<port> that returns 0 iff something is LISTENING.
# Bounded by `timeout` so a filtered port can never hang the smoke test.
tcp_open() { timeout 2 bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null; }

printf '%spi-system smoke test%s — LIVE post-install check  (%s)\n' \
  "${C_BOLD}" "${C_OFF}" "$(date '+%Y-%m-%d %H:%M:%S %z' 2>/dev/null || true)"

# ===========================================================================
# 1. ENVIRONMENT — only run the live checks when Docker is actually available.
#    Off a Pi (no Docker), SKIP cleanly and exit 0 — never a false failure.
# ===========================================================================
section "Environment"
if ! command -v docker >/dev/null 2>&1; then
  record SKIP "Docker present" "the docker CLI is not installed here"
  note "This is the LIVE on-Pi smoke test; there is nothing to check on a box without Docker."
  note "Run it ON the Raspberry Pi after './scripts/pi up'."
  printf '\n%sOVERALL: PASS%s (skipped — Docker not available here)\n' "${C_DIM}" "${C_OFF}"
  exit 0
fi
if ! docker info >/dev/null 2>&1; then
  record SKIP "Docker daemon reachable" "the daemon is not running / not reachable"
  note "Start it (sudo systemctl start docker) and ensure your user is in the 'docker' group, then re-run."
  printf '\n%sOVERALL: PASS%s (skipped — Docker daemon not reachable)\n' "${C_DIM}" "${C_OFF}"
  exit 0
fi
record PASS "Docker reachable" "$(docker --version 2>/dev/null | head -1)"

PROJECT="$(env_get COMPOSE_PROJECT_NAME)"; PROJECT="${PROJECT:-pi-system}"
note "Compose project: ${PROJECT}"

# ===========================================================================
# 2. CORE LIVENESS — the always-on core is up; Caddy owns 80/443; nothing else
#    publishes a host port (the 80/443-only invariant, re-asserted live).
# ===========================================================================
section "Core liveness + the 80/443-only invariant"

container_state() { docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null || true; }

CORE_SERVICES=(caddy portainer uptime-kuma homepage watchtower)
down_core=()
for svc in "${CORE_SERVICES[@]}"; do
  st="$(container_state "${PROJECT}_${svc}")"
  [[ "${st}" == "running" ]] || down_core+=("${svc}(${st:-absent})")
done
if (( ${#down_core[@]} == 0 )); then
  record PASS "Core containers running" "${CORE_SERVICES[*]}"
else
  record FAIL "Core containers running" "not running: ${down_core[*]}" \
    "Bring the core up:  ./scripts/pi up   (then ./scripts/pi status)"
fi

# Caddy must be LISTENING on both host ports.
caddy_ok=1
tcp_open 80  || caddy_ok=0
tcp_open 443 || caddy_ok=0
if (( caddy_ok )); then
  record PASS "Caddy listening on 80 + 443" "host edge is accepting connections"
else
  record FAIL "Caddy listening on 80 + 443" "127.0.0.1:80 and/or :443 not accepting" \
    "Is Caddy up?  docker logs ${PROJECT}_caddy   (and ./scripts/pi status)"
fi

# Enumerate EVERY published host port across the whole project; assert ⊆ {80,443}.
mapfile -t PUB_PORTS < <(
  docker ps --filter "label=com.docker.compose.project=${PROJECT}" --format '{{.Ports}}' 2>/dev/null \
    | tr ',' '\n' \
    | grep -oE '(0\.0\.0\.0|\[?::\]?|[0-9]{1,3}(\.[0-9]{1,3}){3}):[0-9]+->' \
    | sed -E 's/.*:([0-9]+)->.*/\1/' \
    | sort -u
)
stray=()
for p in "${PUB_PORTS[@]:-}"; do
  [[ -z "${p}" ]] && continue
  [[ "${p}" == "80" || "${p}" == "443" ]] || stray+=("${p}")
done
if (( ${#stray[@]} == 0 )); then
  record PASS "Only 80/443 published to the host" "published: ${PUB_PORTS[*]:-none}"
else
  record FAIL "Only 80/443 published to the host" "stray published port(s): ${stray[*]}" \
    "Only Caddy may bind a host port. Remove the 'ports:' from the offending service(s)."
fi

# ===========================================================================
# 3. INTERNAL ISOLATION — internal-only services must NOT be reachable from the
#    host (no leaked port). They live on the `internal` Docker network and are
#    reached by service name; from the host, every one of these must be CLOSED.
# ===========================================================================
section "Internal network isolation (live boundary)"
# port -> service (only the host-facing reachability matters; the service may or
# may not be running — either way it must not answer on the host).
declare -A INTERNAL_PORTS=(
  [5432]="postgres" [3306]="mysql" [27017]="mongo" [6379]="redis"
  [5678]="n8n" [9000]="portainer" [3001]="uptime-kuma" [8080]="keycloak"
)
exposed=()
for port in "${!INTERNAL_PORTS[@]}"; do
  if tcp_open "${port}"; then exposed+=("${INTERNAL_PORTS[$port]}:${port}"); fi
done
if (( ${#exposed[@]} == 0 )); then
  record PASS "Internal services not reachable from host" "all internal ports closed on 127.0.0.1"
else
  record FAIL "Internal services not reachable from host" "REACHABLE: ${exposed[*]}" \
    "An internal service leaked a host port — it must be internal-only (no 'ports:'). This is a network-boundary breach."
fi

# ===========================================================================
# 4. SECRETS — the auditor must report no critical problems (exit 0).
# ===========================================================================
section "Secrets"
if bash "${SCRIPTS}/check-secrets.sh" >/dev/null 2>&1; then
  record PASS "Secrets audit (check-secrets.sh)" "no critical findings (all 11 keys filled)"
else
  record FAIL "Secrets audit (check-secrets.sh)" "critical secret problem(s) found" \
    "See details:  ./scripts/check-secrets.sh    Fix with:  ./scripts/generate-secrets.sh --force"
fi

# ===========================================================================
# 5. BRIDGE HEALTH — the audited control-bridge answers a READ-ONLY action.
#    scripts/bot-exec.sh is the exact host-side handler the Control API reaches
#    over SSH; running a read-only action through it live proves the bridge round-
#    trips and returns data (without needing the panel's Keycloak login).
# ===========================================================================
section "Control bridge (read-only action)"
bridge_out="$(bash "${SCRIPTS}/bot-exec.sh" monitor_metrics 2>/dev/null)"; bridge_rc=$?
if (( bridge_rc == 0 )) && [[ "${bridge_out:0:1}" == "{" ]]; then
  record PASS "Bridge answers a read-only action" "bot-exec monitor_metrics → panel-read JSON (rc 0)"
  note "Same read path the Control API uses (SSH → bot-exec → panel-read); equivalent to 'pi status'."
else
  record FAIL "Bridge answers a read-only action" "bot-exec monitor_metrics rc=${bridge_rc}" \
    "Check the bridge door:  ./scripts/bot-exec.sh monitor_metrics   and  ./scripts/panel-read.sh monitor_metrics"
fi

# ===========================================================================
# 6. ENGINE + SSRF GUARD — the SEO/prospects probe produces a full audit object,
#    and the SSRF guard refuses the cloud-metadata IP (the live safety boundary
#    shared by BOTH the SEO auditor and the prospects organizer).
# ===========================================================================
section "SEO/prospects engine + SSRF guard (live)"

# Keep the engine's data dir consistent between this script, scripts/seo.sh and
# the container mount, so we read back the same audit the container just wrote.
SMOKE_SEO_DATA="${SEO_DATA_DIR:-$(env_get SEO_DATA_DIR)}"; SMOKE_SEO_DATA="${SMOKE_SEO_DATA:-./data/seo}"
case "${SMOKE_SEO_DATA}" in
  /*) SEO_DATA_ABS="${SMOKE_SEO_DATA}" ;;
  ./*) SEO_DATA_ABS="${PROJECT_ROOT}/${SMOKE_SEO_DATA#./}" ;;
  *)  SEO_DATA_ABS="${PROJECT_ROOT}/${SMOKE_SEO_DATA}" ;;
esac
SAFE_NAME="smoke-test"; SSRF_NAME="smoke-ssrf"
safe_latest="${SEO_DATA_ABS}/latest/${SAFE_NAME}.json"
ssrf_latest="${SEO_DATA_ABS}/latest/${SSRF_NAME}.json"
seo_log="$(mktemp 2>/dev/null || echo "${PROJECT_ROOT}/.smoke-seo.$$")"

# Does a stored audit JSON carry all five category scores AND a verdict?
seo_object_ok() {
  local f="$1" k
  [[ -f "${f}" ]] || return 1
  for k in performance accessibility 'best-practices' seo security verdict; do
    grep -qE "\"${k}\"[[:space:]]*:" "${f}" || return 1
  done
  return 0
}

note "running the one-shot SEO auditor (the FIRST run builds the image — may take a few minutes)..."
if SEO_DATA_DIR="${SMOKE_SEO_DATA}" bash "${SCRIPTS}/seo.sh" audit "${SAFE_NAME}" --url "${URL}" >"${seo_log}" 2>&1; then
  if seo_object_ok "${safe_latest}"; then
    okflag="$(grep -oE '"ok"[[:space:]]*:[[:space:]]*(true|false)' "${safe_latest}" | head -1 | grep -oE 'true|false')"
    record PASS "Engine produces a full audit object" "5 category scores + verdict for ${URL} (ok=${okflag:-?})"
    [[ "${okflag}" == "false" ]] && note "The object is well-formed but the fetch was not ok — confirm the --url is a reachable site you own."
  else
    record FAIL "Engine produces a full audit object" "audit ran but the object is missing scores/verdict" \
      "Inspect:  cat ${safe_latest}"
  fi
else
  record FAIL "Engine produces a full audit object" "the SEO auditor did not complete" \
    "Run it directly:  ./scripts/seo.sh audit ${SAFE_NAME} --url ${URL}"
  tail -n 6 "${seo_log}" 2>/dev/null | sed 's/^/         | /'
fi

# SSRF: the cloud-metadata IP MUST be refused (blocked, no fetch). probeUrl never
# throws — it records an ok:false audit whose status names the SSRF block.
SEO_DATA_DIR="${SMOKE_SEO_DATA}" bash "${SCRIPTS}/seo.sh" audit "${SSRF_NAME}" --url "http://169.254.169.254/" >"${seo_log}" 2>&1 || true
if [[ -f "${ssrf_latest}" ]] && grep -q "blocked by SSRF guard" "${ssrf_latest}"; then
  nofetch=""
  grep -qE '"requests"[[:space:]]*:[[:space:]]*0' "${ssrf_latest}" && nofetch=" (no fetch — requests=0)"
  record PASS "SSRF guard refuses cloud-metadata IP" "169.254.169.254 blocked${nofetch}"
else
  record FAIL "SSRF guard refuses cloud-metadata IP" "the metadata IP was NOT blocked" \
    "CRITICAL: the SSRF boundary is not active — inspect services/seo/engine/ssrf-guard.js and ${ssrf_latest}"
fi
rm -f "${seo_log}" 2>/dev/null || true

# ===========================================================================
# 7. NOTIFIER — wired + GATED. A dry-run must send nothing and never leak the
#    token (it is masked). Both "configured" and "not configured" are correct.
# ===========================================================================
section "Outbound notifier (dry-run, gated)"
notify_out="$(printf 'smoke-test go-live probe\n' | TELEGRAM_NOTIFY_DRYRUN=1 bash "${SCRIPTS}/notify-telegram.sh" SMOKE 2>&1)"; notify_rc=$?
token="$(env_get TELEGRAM_BOT_TOKEN)"
leaked=0
if [[ -n "${token}" ]] && printf '%s' "${notify_out}" | grep -qF -- "${token}"; then leaked=1; fi
if (( notify_rc == 0 )) && (( ! leaked )) \
   && printf '%s' "${notify_out}" | grep -qiE 'dry-run|not configured'; then
  if printf '%s' "${notify_out}" | grep -qi 'dry-run'; then
    record PASS "Notifier wired + gated (dry-run)" "would send to your chat; nothing sent, token masked"
  else
    record PASS "Notifier wired + gated (dry-run)" "not configured yet — correctly sends nothing"
    note "Optional: set TELEGRAM_BOT_TOKEN + TELEGRAM_ALERT_CHAT_ID to enable operator alerts (RUNBOOK step 6)."
  fi
elif (( leaked )); then
  record FAIL "Notifier wired + gated (dry-run)" "the dry-run output contained the bot token" \
    "The notifier must NEVER print the token — inspect scripts/notify-telegram.sh"
else
  record FAIL "Notifier wired + gated (dry-run)" "notify-telegram.sh dry-run did not behave as expected (rc=${notify_rc})" \
    "Test it:  echo hi | TELEGRAM_NOTIFY_DRYRUN=1 ./scripts/notify-telegram.sh TEST"
fi

# ===========================================================================
# Summary + the single OVERALL verdict line.
# ===========================================================================
printf '\n%s== Summary ==%s\n' "${C_CYAN}" "${C_OFF}"
printf '  %s%d PASS%s   %s%d WARN%s   %s%d FAIL%s   %s%d SKIP%s\n' \
  "${C_GREEN}" "${pass_n}" "${C_OFF}" "${C_YELLOW}" "${warn_n}" "${C_OFF}" \
  "${C_RED}" "${fail_n}" "${C_OFF}" "${C_DIM}" "${skip_n}" "${C_OFF}"
echo
if (( fail_n > 0 )); then
  printf '%sOVERALL: FAIL%s — %d check(s) failed; fix the hints above before going live.\n' \
    "${C_RED}${C_BOLD}" "${C_OFF}" "${fail_n}" >&2
  exit 1
fi
printf '%sOVERALL: PASS%s — the live stack passed every smoke check. Continue the go-live gate in docs/RUNBOOK.md.\n' \
  "${C_GREEN}${C_BOLD}" "${C_OFF}"
exit 0
