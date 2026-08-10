#!/usr/bin/env bash
# ===========================================================================
# pi-system — CLIENT PROSPECT ORGANIZER helper
# ---------------------------------------------------------------------------
# A self-hosted, operator-owned CRM-lite for a MANUAL client-acquisition workflow.
# YOU find prospects yourself and enter them; this tool ORGANIZES the pipeline and
# ANALYZES a prospect's OWN PUBLIC website (reusing the services/seo engine); then
# YOU contact them MANUALLY. Growth layer #4.
#
# ⚠ BOUNDARY (architectural, NOT a toggle): this tool does NOT scrape Google Maps /
#   LinkedIn / any platform, and does NOT send or bulk-send any outreach. There is
#   deliberately no "send" or "scrape/import" action. Follow-up reminders go to YOU
#   (the operator), never to a prospect. Draft templates are for YOU to copy,
#   personalize and send yourself. See services/prospects/README.md.
#
# It drives the on-demand, profile-gated organizer in services/prospects (profile
# "prospects"), which runs as a ONE-SHOT container and exits — nothing stays
# running, no host ports, gentle on the Pi. The analysis REUSES the SEO engine's
# default no-browser probe (Lighthouse is opt-in, same as scripts/seo.sh).
#
# Usage:
#     ./scripts/prospects.sh <action> [args]
#
#   add "<name>" [--url <u>] [--status <s>] [--note "<t>"]
#                     add a prospect YOU found and entered yourself.
#   list [--status <s>] [--json]            list the pipeline.
#   show <id> [--json]                      show one prospect (notes, history, analysis).
#   update <id> [--status <s>] [--followup <YYYY-MM-DD|clear>] [--url <u>] [--name "<n>"]
#                     move status (validated), set/clear the follow-up date, edit fields.
#   note <id> "<text>"                      append a note (your own observation).
#   followups [--today <YYYY-MM-DD>] [--notify] [--json]
#                     surface follow-ups DUE — a reminder to YOU (optionally pushed
#                     to your OWN channel via PROSPECTS_NOTIFY_CMD). Never the prospect.
#   analyze <id> [--engine probe|lighthouse] [--lh-json <f>] [--locale ar|en] [--pdf] [--depth quick|standard|deep] [--panel] [--competitor <url> ...] [--notify]
#                     run the SEO engine on the prospect's OWN public site; saves a
#                     report you can read, edit and share YOURSELF. With --notify it runs
#                     the FULL automated flow end to end: audit -> verdict -> optional AI
#                     -> Markdown (+ PDF with --pdf) report saved -> rich alert pushed to
#                     YOUR OWN channel -> follow-up reminder set. The alert is always to
#                     YOU, never to the prospect; you still contact prospects manually.
#                     --depth picks the cost-vs-depth level (quick=free/0 AI calls,
#                     standard≈1 AI call, deep=multi-specialist panel ≈ up to 7 AI calls);
#                     legacy --panel is treated as --depth deep. With no --depth: quick
#                     when no AI key is set, standard when a key is present (overridable
#                     via SEO_DEFAULT_DEPTH in .env). See .env.example for the cost note.
#   assist <id>       OPTIONAL AI decision assist (advisory). On the latest analysis +
#                     YOUR notes/status, suggest a lead score + a next step from a fixed
#                     allowlist + a one-line why. Needs an AI key; NEVER contacts anyone.
#   draft <id> [--kind outreach|referral|content] [--locale ar|en]
#                     OPTIONAL AI-assisted drafts built FROM the prospect's audit: a
#                     value-first outreach message (referencing the 1-2 biggest issues), a
#                     referral-request, and an educational content snippet — bilingual.
#                     Inert (deterministic templates) without an AI key. DRAFTS ONLY —
#                     copy, edit, and send yourself; this NEVER sends.
#   template <kind> [<id>] [--lang en|ar]   print a DRAFT (intro|followup|audit-offer)
#                     to copy, personalize and send manually. This NEVER sends.
#   status                                  terse pipeline overview.
#   help                                    show this help.
#
# Examples:
#     ./scripts/prospects.sh add "Acme Dental Clinic" --url https://acme.example --note "met at expo"
#     ./scripts/prospects.sh update acme-dental-clinic --status contacted
#     ./scripts/prospects.sh note acme-dental-clinic "Left a message with reception"
#     ./scripts/prospects.sh update acme-dental-clinic --followup 2026-06-01
#     ./scripts/prospects.sh analyze acme-dental-clinic
#     ./scripts/prospects.sh analyze acme-dental-clinic --notify          # full automated flow
#     ./scripts/prospects.sh analyze acme-dental-clinic --pdf --notify --locale ar
#     ./scripts/prospects.sh followups --notify
#     ./scripts/prospects.sh template audit-offer acme-dental-clinic
#
# Schedule a follow-up reminder with ./scripts/prospects-install-cron.sh.
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# shellcheck source=scripts/lib/prospects-lib.sh
. "${SCRIPT_DIR}/lib/prospects-lib.sh"
# shellcheck source=scripts/lib/lock-lib.sh
. "${SCRIPT_DIR}/lib/lock-lib.sh"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[prospects]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

BASE_COMPOSE="infrastructure/docker-compose.yml"
PROSPECTS_COMPOSE="services/prospects/prospects.compose.yml"
PROFILE="prospects"
DATA_DIR="${PROSPECTS_DATA_DIR:-./data/prospects}"

usage() { sed -n '2,69p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- Parse: <action> [positional ...] [--flags] ----------------------------
ACTION="${1:-help}"
shift || true

if [[ "${ACTION}" == "-h" || "${ACTION}" == "--help" ]]; then ACTION="help"; fi
if [[ "${ACTION}" == "help" ]]; then usage; exit 0; fi

if ! prospects_valid_action "${ACTION}"; then
  err "Unknown action: '${ACTION}'. Valid: ${PROSPECTS_ACTIONS}."
  usage; exit 1
fi

# Flag values (empty = not provided). Booleans default 0.
F_NAME="" F_URL="" F_STATUS="" F_NOTE="" F_FOLLOWUP="" F_TODAY="" F_ENGINE="probe"
F_LHJSON="" F_KIND="" F_LANG="en" F_LOCALE="" F_TEXT="" F_DEPTH="" B_JSON=0 B_NOTIFY=0 B_PDF=0 B_PANEL=0
F_COMPETITORS=()  # repeatable --competitor <url>, bounded by PROSPECTS_MAX_COMPETITORS
POSITIONAL=()

# helper: require a value for a flag
reqval() { [[ $# -ge 2 && -n "${2:-}" && "${2:0:2}" != "--" ]] || { err "$1 requires a value."; exit 1; }; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)      reqval "$1" "${2:-}"; F_NAME="$2"; shift 2 ;;
    --name=*)    F_NAME="${1#*=}"; shift ;;
    --url)       reqval "$1" "${2:-}"; F_URL="$2"; shift 2 ;;
    --url=*)     F_URL="${1#*=}"; shift ;;
    --status)    reqval "$1" "${2:-}"; F_STATUS="$2"; shift 2 ;;
    --status=*)  F_STATUS="${1#*=}"; shift ;;
    --note)      reqval "$1" "${2:-}"; F_NOTE="$2"; shift 2 ;;
    --note=*)    F_NOTE="${1#*=}"; shift ;;
    --text)      reqval "$1" "${2:-}"; F_TEXT="$2"; shift 2 ;;
    --text=*)    F_TEXT="${1#*=}"; shift ;;
    --followup)  reqval "$1" "${2:-}"; F_FOLLOWUP="$2"; shift 2 ;;
    --followup=*) F_FOLLOWUP="${1#*=}"; shift ;;
    --today)     reqval "$1" "${2:-}"; F_TODAY="$2"; shift 2 ;;
    --today=*)   F_TODAY="${1#*=}"; shift ;;
    --engine)    reqval "$1" "${2:-}"; F_ENGINE="$2"; shift 2 ;;
    --engine=*)  F_ENGINE="${1#*=}"; shift ;;
    --lh-json)   reqval "$1" "${2:-}"; F_LHJSON="$2"; shift 2 ;;
    --lh-json=*) F_LHJSON="${1#*=}"; shift ;;
    --kind)      reqval "$1" "${2:-}"; F_KIND="$2"; shift 2 ;;
    --kind=*)    F_KIND="${1#*=}"; shift ;;
    --lang)      reqval "$1" "${2:-}"; F_LANG="$2"; shift 2 ;;
    --lang=*)    F_LANG="${1#*=}"; shift ;;
    --locale)    reqval "$1" "${2:-}"; F_LOCALE="$2"; shift 2 ;;
    --locale=*)  F_LOCALE="${1#*=}"; shift ;;
    --depth)     reqval "$1" "${2:-}"; F_DEPTH="$2"; shift 2 ;;
    --depth=*)   F_DEPTH="${1#*=}"; shift ;;
    --competitor)   reqval "$1" "${2:-}"; F_COMPETITORS+=("$2"); shift 2 ;;
    --competitor=*) F_COMPETITORS+=("${1#*=}"); shift ;;
    --json)      B_JSON=1; shift ;;
    --notify)    B_NOTIFY=1; shift ;;
    --pdf)       B_PDF=1; shift ;;
    --panel)     B_PANEL=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    --*)         err "Unknown option: '$1'."; exit 1 ;;
    *)           POSITIONAL+=("$1"); shift ;;
  esac
done

# Map friendly positionals into the per-action fields.
case "${ACTION}" in
  add)      [[ -n "${F_NAME}" ]] || F_NAME="${POSITIONAL[0]:-}" ;;
  show|update|analyze|assist|draft) ID="${POSITIONAL[0]:-}" ;;
  note)     ID="${POSITIONAL[0]:-}"; [[ -n "${F_TEXT}" ]] || F_TEXT="${POSITIONAL[*]:1}" ;;
  template) [[ -n "${F_KIND}" ]] || F_KIND="${POSITIONAL[0]:-}"; ID="${POSITIONAL[1]:-}" ;;
esac

# --- Early, friendly validation (NO docker needed — mirrors scripts/seo.sh) --
case "${ACTION}" in
  add)
    [[ -n "${F_NAME}" ]] || { err 'add needs a business name. e.g. ./scripts/prospects.sh add "Acme Dental" --url https://...'; exit 1; }
    [[ -z "${F_STATUS}" ]] || prospects_valid_status "${F_STATUS}" || { err "Invalid --status '${F_STATUS}'. Valid: ${PROSPECTS_STATUSES}."; exit 1; }
    [[ -z "${F_URL}" ]] || prospects_valid_url "${F_URL}" || { err "Invalid --url '${F_URL}' (must be http(s)://...)."; exit 1; }
    ;;
  list)
    [[ -z "${F_STATUS}" ]] || prospects_valid_status "${F_STATUS}" || { err "Invalid --status '${F_STATUS}'. Valid: ${PROSPECTS_STATUSES}."; exit 1; }
    ;;
  show)
    prospects_valid_id "${ID:-}" || { err "show needs a valid prospect id. e.g. ./scripts/prospects.sh show acme-dental"; exit 1; }
    ;;
  update)
    prospects_valid_id "${ID:-}" || { err "update needs a valid prospect id."; exit 1; }
    [[ -z "${F_STATUS}" ]] || prospects_valid_status "${F_STATUS}" || { err "Invalid --status '${F_STATUS}'. Valid: ${PROSPECTS_STATUSES}."; exit 1; }
    [[ -z "${F_FOLLOWUP}" || "${F_FOLLOWUP}" == "clear" ]] || prospects_valid_date "${F_FOLLOWUP}" || { err "Invalid --followup '${F_FOLLOWUP}' (use YYYY-MM-DD or 'clear')."; exit 1; }
    [[ -z "${F_URL}" || "${F_URL}" == "clear" ]] || prospects_valid_url "${F_URL}" || { err "Invalid --url '${F_URL}'."; exit 1; }
    [[ -n "${F_STATUS}${F_FOLLOWUP}${F_URL}${F_NAME}" ]] || { err "update needs at least one of --status, --followup, --url, --name."; exit 1; }
    ;;
  note)
    prospects_valid_id "${ID:-}" || { err "note needs a valid prospect id."; exit 1; }
    [[ -n "${F_TEXT// /}" ]] || { err 'note needs text. e.g. ./scripts/prospects.sh note acme-dental "called reception"'; exit 1; }
    ;;
  analyze)
    prospects_valid_id "${ID:-}" || { err "analyze needs a valid prospect id."; exit 1; }
    prospects_valid_engine "${F_ENGINE}" || { err "Invalid --engine '${F_ENGINE}'. Valid: ${PROSPECTS_ENGINES}."; exit 1; }
    [[ "${F_ENGINE}" != "lighthouse" || -n "${F_LHJSON}" ]] || { err "--engine lighthouse requires --lh-json <path under /data> (produce it via scripts/seo.sh)."; exit 1; }
    [[ -z "${F_LOCALE}" ]] || prospects_valid_lang "${F_LOCALE}" || { err "Invalid --locale '${F_LOCALE}'. Valid: ${PROSPECTS_LANGS}."; exit 1; }
    # --depth validated BEFORE Docker so an unknown value never spends a probe call.
    # The engine validates again (defence in depth) using the same depth list.
    [[ -z "${F_DEPTH}" ]] || prospects_valid_depth "${F_DEPTH}" || { err "Invalid --depth '${F_DEPTH}'. Valid: ${PROSPECTS_DEPTHS}."; exit 1; }
    # --competitor URLs validated BEFORE Docker: each must be http(s) and the COUNT
    # is bounded. The engine also bound-checks + the SSRF guard refuses internal targets.
    if (( ${#F_COMPETITORS[@]} > PROSPECTS_MAX_COMPETITORS )); then
      err "Too many --competitor URLs (${#F_COMPETITORS[@]}) — max ${PROSPECTS_MAX_COMPETITORS}."
      exit 1
    fi
    for _c in "${F_COMPETITORS[@]:-}"; do
      [[ -n "${_c}" ]] || continue
      prospects_valid_url "${_c}" || { err "Invalid --competitor URL '${_c}' (must be http(s)://...)."; exit 1; }
    done
    unset _c
    ;;
  assist)
    prospects_valid_id "${ID:-}" || { err "assist needs a valid prospect id. e.g. ./scripts/prospects.sh assist acme-dental"; exit 1; }
    ;;
  draft)
    prospects_valid_id "${ID:-}" || { err "draft needs a valid prospect id. e.g. ./scripts/prospects.sh draft acme-dental"; exit 1; }
    [[ -z "${F_KIND}" ]] || prospects_valid_draft_kind "${F_KIND}" || { err "Invalid --kind '${F_KIND}'. Valid: ${PROSPECTS_DRAFT_KINDS}."; exit 1; }
    [[ -z "${F_LOCALE}" ]] || prospects_valid_lang "${F_LOCALE}" || { err "Invalid --locale '${F_LOCALE}'. Valid: ${PROSPECTS_LANGS}."; exit 1; }
    ;;
  followups)
    [[ -z "${F_TODAY}" ]] || prospects_valid_date "${F_TODAY}" || { err "Invalid --today '${F_TODAY}' (use YYYY-MM-DD)."; exit 1; }
    ;;
  template)
    prospects_valid_template "${F_KIND}" || { err "template needs a kind. Valid: ${PROSPECTS_TEMPLATES}. e.g. ./scripts/prospects.sh template intro <id>"; exit 1; }
    prospects_valid_lang "${F_LANG}" || { err "Invalid --lang '${F_LANG}'. Valid: ${PROSPECTS_LANGS}."; exit 1; }
    [[ -z "${ID:-}" ]] || prospects_valid_id "${ID}" || { err "Invalid prospect id '${ID}'."; exit 1; }
    ;;
esac

# --- Preconditions (docker only needed for actions that run the container) ---
need_docker() {
  if ! docker compose version >/dev/null 2>&1; then
    err "Docker Compose v2 not available. Run ./scripts/setup.sh to diagnose."
    exit 1
  fi
  [[ -f ".env" ]] || { err ".env not found. Run ./scripts/setup.sh first, then edit .env."; exit 1; }
  for f in "${BASE_COMPOSE}" "${PROSPECTS_COMPOSE}"; do
    [[ -f "${f}" ]] || { err "Missing required file: ${f}"; exit 1; }
  done
  mkdir -p "${DATA_DIR}"
}

compose() {
  docker compose --env-file .env --project-directory "${PROJECT_ROOT}" \
    -f "${BASE_COMPOSE}" -f "${PROSPECTS_COMPOSE}" --profile "${PROFILE}" "$@"
}

# Assemble the engine argv for the current action, then run it one-shot.
run_engine() {
  local -a a=("$1"); shift
  a+=("$@")
  need_docker
  compose run --rm prospects "${a[@]}"
}

case "${ACTION}" in
  add)
    ARGS=(--name "${F_NAME}")
    [[ -n "${F_URL}" ]]    && ARGS+=(--url "${F_URL}")
    [[ -n "${F_STATUS}" ]] && ARGS+=(--status "${F_STATUS}")
    [[ -n "${F_NOTE}" ]]   && ARGS+=(--note "${F_NOTE}")
    run_engine add "${ARGS[@]}"
    ;;
  list)
    ARGS=()
    [[ -n "${F_STATUS}" ]] && ARGS+=(--status "${F_STATUS}")
    [[ "${B_JSON}" -eq 1 ]] && ARGS+=(--json)
    run_engine list "${ARGS[@]}"
    ;;
  show)
    ARGS=(--id "${ID}")
    [[ "${B_JSON}" -eq 1 ]] && ARGS+=(--json)
    run_engine show "${ARGS[@]}"
    ;;
  update)
    ARGS=(--id "${ID}")
    [[ -n "${F_STATUS}" ]]   && ARGS+=(--status "${F_STATUS}")
    [[ -n "${F_FOLLOWUP}" ]] && ARGS+=(--followup "${F_FOLLOWUP}")
    [[ -n "${F_URL}" ]]      && ARGS+=(--url "${F_URL}")
    [[ -n "${F_NAME}" ]]     && ARGS+=(--name "${F_NAME}")
    run_engine update "${ARGS[@]}"
    ;;
  note)
    run_engine note --id "${ID}" --text "${F_TEXT}"
    ;;
  followups)
    ARGS=()
    [[ -n "${F_TODAY}" ]]    && ARGS+=(--today "${F_TODAY}")
    [[ "${B_NOTIFY}" -eq 1 ]] && ARGS+=(--notify)
    [[ "${B_JSON}" -eq 1 ]]   && ARGS+=(--json)
    run_engine followups "${ARGS[@]}"
    ;;
  analyze)
    if [[ "${B_NOTIFY}" -eq 1 ]]; then
      _pdf_note=""; [[ "${B_PDF}" -eq 1 ]] && _pdf_note=" (+pdf)"
      log "Running the FULL analysis pipeline for '${ID}' (${F_ENGINE} engine${F_DEPTH:+, --depth ${F_DEPTH}}): audit -> verdict -> AI -> report${_pdf_note} -> operator alert -> follow-up ..."
    else
      log "Analyzing the PUBLIC site of '${ID}' with the ${F_ENGINE} engine${F_DEPTH:+ at --depth ${F_DEPTH}} (reusing the SEO engine) ..."
    fi
    [[ "${F_ENGINE}" == "lighthouse" ]] && warn "Lighthouse ingests a JSON you produced via scripts/seo.sh; place it under ${DATA_DIR} and pass --lh-json /data/<file>."
    ARGS=(--id "${ID}" --engine "${F_ENGINE}")
    [[ -n "${F_LHJSON}" ]] && ARGS+=(--lh-json "${F_LHJSON}")
    [[ -n "${F_LOCALE}" ]] && ARGS+=(--locale "${F_LOCALE}")
    [[ -n "${F_DEPTH}" ]]  && ARGS+=(--depth "${F_DEPTH}")
    for _u in "${F_COMPETITORS[@]:-}"; do [[ -n "${_u}" ]] && ARGS+=(--competitor "${_u}"); done
    unset _u
    [[ "${B_PDF}" -eq 1 ]] && ARGS+=(--pdf)
    [[ "${B_PANEL}" -eq 1 ]] && ARGS+=(--panel)
    [[ "${B_NOTIFY}" -eq 1 ]] && ARGS+=(--notify)
    # SINGLE-FLIGHT: an analysis runs the probe + writes the prospect store; never let a
    # scheduled run and a manual one overlap. A held lock → skip cleanly (exit 0).
    ANALYZE_LOCK="${DATA_DIR}/analyze.lock"
    if ! lock_acquire "${ANALYZE_LOCK}"; then
      warn "Another prospect analysis is already running (single-flight) — skipping this run."
      exit 0
    fi
    trap 'lock_release "${ANALYZE_LOCK}"' EXIT
    run_engine analyze "${ARGS[@]}"
    log "Review/edit the report, then share it YOURSELF — this tool does not send it."
    ;;
  assist)
    log "AI decision assist for '${ID}' (advisory only — needs an AI key; contacts no one) ..."
    run_engine assist --id "${ID}"
    ;;
  draft)
    log "Building copy-paste drafts for '${ID}' (AI-assisted if an AI key is set, else templates) ..."
    warn "Drafts are operator-only: copy, personalize, and send them YOURSELF — this tool sends nothing."
    ARGS=(--id "${ID}")
    [[ -n "${F_KIND}" ]]   && ARGS+=(--kind "${F_KIND}")
    [[ -n "${F_LOCALE}" ]] && ARGS+=(--locale "${F_LOCALE}")
    run_engine draft "${ARGS[@]}"
    ;;
  template)
    ARGS=(--kind "${F_KIND}" --lang "${F_LANG}")
    [[ -n "${ID:-}" ]] && ARGS+=(--id "${ID}")
    run_engine template "${ARGS[@]}"
    ;;
  status)
    run_engine status
    if [[ -f "${DATA_DIR}/last-followups.txt" ]]; then
      log "Last follow-up reminder:"
      sed 's/^/   /' "${DATA_DIR}/last-followups.txt"
    fi
    ;;
esac
