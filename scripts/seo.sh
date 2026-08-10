#!/usr/bin/env bash
# ===========================================================================
# pi-system — SEO & site-quality helper
# ---------------------------------------------------------------------------
# Audit the sites you OWN (your portfolio + the client sites you host), see results
# over time, and get FREE, deterministic, rule-based recommendations (with an
# OPTIONAL, off-by-default AI enrichment — see the SEO section of .env.example).
#
# It drives the on-demand, profile-gated auditor in services/seo (profile "seo"),
# which runs as a ONE-SHOT container and exits — nothing stays running, no host
# ports, gentle on the Pi. The DEFAULT engine is a lightweight Node probe (no
# browser); the real Lighthouse engine (headless Chromium, heavy) is opt-in.
#
# Usage:
#     ./scripts/seo.sh <action> [args]
#
#   audit <site>|all [--url <url>] [--engine probe|lighthouse] [--depth quick|standard|deep] [--panel] [--competitor <url> ...]
#                     run an audit now. <site> is a name in your sites list
#                     (data/seo/sites.conf); `all` audits every listed site,
#                     sequentially (one at a time — gentle on the Pi). --url
#                     audits an ad-hoc URL not in the list. --engine lighthouse
#                     uses the heavy, real-Chromium engine (opt-in). --depth picks the
#                     cost-vs-depth level (quick=free/0 AI calls, standard≈1 AI call,
#                     deep=specialist panel ≈ up to 7 AI calls); legacy --panel is
#                     treated as --depth deep. With no --depth: quick when no AI key
#                     is set, standard when a key is present (overridable via
#                     SEO_DEFAULT_DEPTH in .env). --competitor <url> (repeatable, max 3)
#                     adds an operator-supplied competitor URL probed by the SAME
#                     SSRF-guarded engine; the report gains a side-by-side
#                     "Competitor comparison" section. See .env.example for the cost note.
#   reaudit <site> [--url <url>] [--depth quick|standard|deep] [--panel]
#                     re-audit an EXISTING site and surface WHAT CHANGED vs the
#                     previous run (a "Changes since last audit" section in the report).
#                     An operator heads-up is pushed ONLY on a meaningful change (a new
#                     critical/high finding, a tier drop, or the site going offline) via
#                     the gated notifier — operator-only, never the client. Cron-friendly
#                     for monitoring existing clients (off by default). Single-flight.
#                     --depth has the SAME meaning as on `audit` (default: key-presence).
#   list              list audited sites with their latest scores.
#   trend <site>      show per-category first→latest score change for a site.
#   recommend <site> [--depth quick|standard|deep] [--panel]
#                     re-print recommendations from the LATEST stored audit
#                     (no new network probe; honours the AI env if set).
#                     --depth has the SAME meaning as on `audit` (default: key-presence).
#   pdf <site> [--locale ar|en] [--depth quick|standard|deep] [--panel]
#                     OPTIONAL export: build the bilingual prospect report from the
#                     LATEST stored audit and write a clean, print-ready HTML (always)
#                     + a PDF (only if you opted in to a renderer — see the README)
#                     under data/seo/reports/. Off by default; if no renderer is
#                     configured it keeps the Markdown + HTML (open it and "Save as
#                     PDF" in any browser). Locale defaults to Arabic (ar).
#                     --depth has the SAME meaning as on `audit` (default: key-presence).
#   content-ideas [--locale ar|en]
#                     mine YOUR OWN accumulated audit history for recurring issue patterns
#                     and propose data-backed, EDUCATIONAL content topics to attract inbound
#                     clients. Reads ONLY your local stores (data/seo/audits + best-effort
#                     the prospects store) — scrapes nothing, sends nothing. AI-assisted
#                     (reuses AI_*); inert without a key (deterministic templates).
#   status            terse overview + the last audit summary.
#   help              show this help.
#
# Examples:
#     ./scripts/seo.sh audit happy-teeth
#     ./scripts/seo.sh audit all
#     ./scripts/seo.sh audit my-portfolio --engine lighthouse
#     ./scripts/seo.sh trend happy-teeth
#     ./scripts/seo.sh pdf happy-teeth --locale ar
#
# Schedule regular audits with ./scripts/seo-install-cron.sh (host cron pattern).
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# shellcheck source=scripts/lib/seo-lib.sh
. "${SCRIPT_DIR}/lib/seo-lib.sh"
# shellcheck source=scripts/lib/lock-lib.sh
. "${SCRIPT_DIR}/lib/lock-lib.sh"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[seo]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
SEO_COMPOSE="services/seo/seo.compose.yml"
PROFILE="seo"
DATA_DIR="${SEO_DATA_DIR:-./data/seo}"

usage() { sed -n '2,59p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- Parse: <action> [positional] [--flags] --------------------------------
ACTION="${1:-help}"
shift || true

SITE="" URL="" ENGINE="probe" LOCALE="" PANEL=0 DEPTH=""
COMPETITORS=()   # repeatable --competitor <url>, bounded by SEO_MAX_COMPETITORS
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url)     [[ $# -ge 2 ]] || { err "--url requires a value."; exit 1; }; URL="$2"; shift 2 ;;
    --url=*)   URL="${1#*=}"; shift ;;
    --engine)  [[ $# -ge 2 ]] || { err "--engine requires a value."; exit 1; }; ENGINE="$2"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    --locale)  [[ $# -ge 2 ]] || { err "--locale requires a value."; exit 1; }; LOCALE="$2"; shift 2 ;;
    --locale=*) LOCALE="${1#*=}"; shift ;;
    --depth)   [[ $# -ge 2 ]] || { err "--depth requires a value."; exit 1; }; DEPTH="$2"; shift 2 ;;
    --depth=*) DEPTH="${1#*=}"; shift ;;
    --competitor)   [[ $# -ge 2 ]] || { err "--competitor requires a URL."; exit 1; }; COMPETITORS+=("$2"); shift 2 ;;
    --competitor=*) COMPETITORS+=("${1#*=}"); shift ;;
    --panel)   PANEL=1; shift ;;
    -h|--help) ACTION="help"; shift ;;
    --*)       err "Unknown option: '$1'."; exit 1 ;;
    *)         POSITIONAL+=("$1"); shift ;;
  esac
done
SITE="${POSITIONAL[0]:-}"

if [[ "${ACTION}" == "help" || "${ACTION}" == "-h" || "${ACTION}" == "--help" ]]; then
  usage; exit 0
fi

if ! seo_valid_action "${ACTION}"; then
  err "Unknown action: '${ACTION}'. Valid: ${SEO_ACTIONS}."
  usage; exit 1
fi
if ! seo_valid_engine "${ENGINE}"; then
  err "Unknown engine: '${ENGINE}'. Valid: ${SEO_ENGINES}."
  exit 1
fi
# --depth validated BEFORE Docker so an unknown value never spends a container.
# The engine validates again (defence in depth) using the same DEPTHS list.
if [[ -n "${DEPTH}" ]] && ! seo_valid_depth "${DEPTH}"; then
  err "Unknown depth: '${DEPTH}'. Valid: ${SEO_DEPTHS}."
  exit 1
fi
# --competitor validated BEFORE Docker: each URL must be http(s) and the COUNT is
# bounded by SEO_MAX_COMPETITORS. The engine ALSO bounds + the SSRF guard ALSO
# refuses an internal target — defence in depth.
if (( ${#COMPETITORS[@]} > SEO_MAX_COMPETITORS )); then
  err "Too many --competitor URLs (${#COMPETITORS[@]}) — max ${SEO_MAX_COMPETITORS}."
  exit 1
fi
for _c in "${COMPETITORS[@]:-}"; do
  [[ -n "${_c}" ]] || continue
  if ! seo_valid_url "${_c}"; then
    err "Invalid --competitor URL: '${_c}' (must be http(s)://...)."
    exit 1
  fi
done
unset _c

# --- Preconditions (docker only needed for actions that run a container) ----
need_docker() {
  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
    exit 1
  fi
  [[ -f ".env" ]] || { err ".env not found. Run ./scripts/setup.sh first, then edit .env."; exit 1; }
  for f in "${BASE_COMPOSE}" "${SEO_COMPOSE}"; do
    [[ -f "${f}" ]] || { err "Missing required file: ${f}"; exit 1; }
  done
  mkdir -p "${DATA_DIR}"
}

compose() {
  docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
    -f "${BASE_COMPOSE}" -f "${SEO_COMPOSE}" --profile "${PROFILE}" "$@"
}

SITES_FILE="$(seo_sites_file "${PROJECT_ROOT}")"

# Run one audit for a resolved name + URL using the chosen engine.
run_one_audit() {
  local name="$1" url="$2"
  log "Auditing '${name}' (${url}) with the ${ENGINE} engine${DEPTH:+ at --depth ${DEPTH}}${COMPETITORS[*]:+ (+${#COMPETITORS[@]} competitor(s))} ..."
  if [[ "${ENGINE}" == "lighthouse" ]]; then
    warn "The lighthouse engine launches headless Chromium — heavy on a Pi. One-shot."
    warn "Run it ONLY against sites you OWN: unlike the default probe, Chromium follows"
    warn "redirects itself and is NOT behind the SSRF guard. (Prospects never use it.)"
    compose run --rm seo-lighthouse "${name}" "${url}"
  else
    local -a extra=()
    [[ "${PANEL}" -eq 1 ]] && extra+=(--panel)
    [[ -n "${DEPTH}" ]]   && extra+=(--depth "${DEPTH}")
    local _u
    for _u in "${COMPETITORS[@]:-}"; do [[ -n "${_u}" ]] && extra+=(--competitor "${_u}"); done
    compose run --rm seo-auditor audit --name "${name}" --url "${url}" "${extra[@]}"
  fi
}

case "${ACTION}" in
  audit)
    need_docker
    if [[ -z "${SITE}" ]]; then
      err "audit needs a site name (or 'all'). e.g. ./scripts/seo.sh audit happy-teeth"
      exit 1
    fi
    # SINGLE-FLIGHT: never let a scheduled audit and a manual one (or two scheduled
    # runs) overlap and clobber the shared store. A held lock means "already running"
    # → skip cleanly (exit 0), so an overlapping cron tick is a no-op, not an error.
    AUDIT_LOCK="${DATA_DIR}/audit.lock"
    if ! lock_acquire "${AUDIT_LOCK}"; then
      warn "Another SEO audit is already running (single-flight) — skipping this run."
      exit 0
    fi
    trap 'lock_release "${AUDIT_LOCK}"' EXIT
    if [[ "${SITE}" == "all" ]]; then
      if [[ ! -f "${SITES_FILE}" ]]; then
        err "No sites list at ${SITES_FILE}."
        err "Create it:  mkdir -p data/seo && cp services/seo/sites.example.conf ${SITES_FILE}"
        exit 1
      fi
      mapfile -t NAMES < <(seo_list_names "${SITES_FILE}")
      if [[ ${#NAMES[@]} -eq 0 ]]; then
        err "Sites list ${SITES_FILE} has no usable entries (see services/seo/sites.example.conf)."
        exit 1
      fi
      log "Auditing ${#NAMES[@]} site(s) sequentially ..."
      for n in "${NAMES[@]}"; do
        u="$(seo_lookup_url "${SITES_FILE}" "${n}")" || { warn "no URL for '${n}' — skipped"; continue; }
        run_one_audit "${n}" "${u}"
      done
      log "Done. See ./scripts/seo.sh list  (reports under ${DATA_DIR}/reports/)."
    else
      seo_valid_name "${SITE}" || { err "Invalid site name '${SITE}' (lowercase, letter first, [a-z0-9-], 2-40)."; exit 1; }
      if [[ -z "${URL}" ]]; then
        if [[ -f "${SITES_FILE}" ]] && URL="$(seo_lookup_url "${SITES_FILE}" "${SITE}")"; then
          :
        else
          err "No URL for '${SITE}'. Add it to ${SITES_FILE} (see services/seo/sites.example.conf)"
          err "or pass one explicitly:  ./scripts/seo.sh audit ${SITE} --url https://..."
          exit 1
        fi
      fi
      run_one_audit "${SITE}" "${URL}"
      log "Done. See ./scripts/seo.sh trend ${SITE}  (report under ${DATA_DIR}/reports/)."
    fi
    ;;

  reaudit)
    need_docker
    seo_valid_name "${SITE}" || { err "reaudit needs a valid site name. e.g. ./scripts/seo.sh reaudit happy-teeth"; exit 1; }
    if [[ -z "${URL}" ]]; then
      if [[ -f "${SITES_FILE}" ]] && URL="$(seo_lookup_url "${SITES_FILE}" "${SITE}")"; then
        :
      else
        err "No URL for '${SITE}'. Add it to ${SITES_FILE} (see services/seo/sites.example.conf)"
        err "or pass one explicitly:  ./scripts/seo.sh reaudit ${SITE} --url https://..."
        exit 1
      fi
    fi
    # SINGLE-FLIGHT: a re-audit writes the SAME store as an audit, so it shares the
    # audit lock — a scheduled re-audit and a manual audit can never overlap. A held
    # lock means "already running" → skip cleanly (exit 0), so an overlapping cron tick
    # is a no-op, not an error.
    AUDIT_LOCK="${DATA_DIR}/audit.lock"
    if ! lock_acquire "${AUDIT_LOCK}"; then
      warn "Another SEO audit/re-audit is already running (single-flight) — skipping this run."
      exit 0
    fi
    trap 'lock_release "${AUDIT_LOCK}"' EXIT
    log "Re-auditing '${SITE}' (${URL}) and diffing against the previous run${DEPTH:+ at --depth ${DEPTH}} ..."
    reaudit_extra=()
    [[ "${PANEL}" -eq 1 ]] && reaudit_extra+=(--panel)
    [[ -n "${DEPTH}" ]]   && reaudit_extra+=(--depth "${DEPTH}")
    for _u in "${COMPETITORS[@]:-}"; do [[ -n "${_u}" ]] && reaudit_extra+=(--competitor "${_u}"); done
    unset _u
    compose run --rm seo-auditor reaudit --name "${SITE}" --url "${URL}" "${reaudit_extra[@]}"
    log "Done. See the 'Changes since last audit' section in the report under ${DATA_DIR}/reports/."
    log "An operator heads-up is sent ONLY on a meaningful change (new critical/high, tier drop, or offline)."
    ;;

  list)
    need_docker
    compose run --rm seo-auditor list
    ;;

  trend)
    need_docker
    seo_valid_name "${SITE}" || { err "trend needs a valid site name. e.g. ./scripts/seo.sh trend happy-teeth"; exit 1; }
    compose run --rm seo-auditor trend --name "${SITE}"
    ;;

  recommend)
    need_docker
    seo_valid_name "${SITE}" || { err "recommend needs a valid site name. e.g. ./scripts/seo.sh recommend happy-teeth"; exit 1; }
    rec_args=(recommend --name "${SITE}")
    [[ "${PANEL}" -eq 1 ]] && rec_args+=(--panel)
    [[ -n "${DEPTH}" ]]   && rec_args+=(--depth "${DEPTH}")
    compose run --rm seo-auditor "${rec_args[@]}"
    ;;

  pdf)
    need_docker
    seo_valid_name "${SITE}" || { err "pdf needs a valid site name. e.g. ./scripts/seo.sh pdf happy-teeth"; exit 1; }
    log "Exporting the prospect report for '${SITE}' (HTML always; PDF only if a renderer is opt-in) ..."
    warn "PDF export is OFF by default. Without a renderer it keeps the Markdown + a print-ready"
    warn "HTML under ${DATA_DIR}/reports/ — open it and 'Save as PDF'. See services/seo/README.md."
    pdf_args=(report-pdf --name "${SITE}")
    [[ -n "${LOCALE}" ]] && pdf_args+=(--locale "${LOCALE}")
    [[ "${PANEL}" -eq 1 ]] && pdf_args+=(--panel)
    [[ -n "${DEPTH}" ]]   && pdf_args+=(--depth "${DEPTH}")
    compose run --rm seo-auditor "${pdf_args[@]}"
    log "Done. Artifacts under ${DATA_DIR}/reports/."
    ;;

  content-ideas)
    need_docker
    log "Mining your local audit history for recurring patterns + content ideas ..."
    warn "Reads ONLY your local data (data/seo/audits + best-effort the prospects store) — scrapes nothing, sends nothing."
    ARGS=()
    [[ -n "${LOCALE}" ]] && ARGS+=(--locale "${LOCALE}")
    compose run --rm seo-auditor content-ideas "${ARGS[@]}"
    ;;

  status)
    log "SEO auditor status (results under ${DATA_DIR}):"
    if [[ -f "${DATA_DIR}/last-summary.txt" ]]; then
      log "Last audit summary:"
      sed 's/^/   /' "${DATA_DIR}/last-summary.txt"
    else
      warn "No audits recorded yet. Run: ./scripts/seo.sh audit <site>"
    fi
    if [[ -f "${SITES_FILE}" ]]; then
      log "Configured sites:"
      seo_list_names "${SITES_FILE}" | sed 's/^/   - /' || true
    else
      warn "No sites list yet. Copy services/seo/sites.example.conf to ${SITES_FILE}."
    fi
    ;;
esac
