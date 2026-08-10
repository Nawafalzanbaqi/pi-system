#!/usr/bin/env bash
# ===========================================================================
# pi-system — prospect organizer, PURE LOGIC library (sourced by prospects.sh)
# ---------------------------------------------------------------------------
# Side-effect-free shell functions: action/argument validation, the status set +
# transition map, and id slugging. Kept apart from scripts/prospects.sh so it can
# be unit-tested offline (tests/prospects/run.sh) WITHOUT Docker — exactly like
# scripts/lib/{seo,ctl,bot,startup}-lib.sh.
#
# BOUNDARY REMINDER (architectural, not a toggle): there is deliberately NO "send"
# action and NO "scrape/import" action here or in scripts/prospects.sh. This tool
# ORGANIZES operator-entered data and ANALYZES a prospect's OWN public site; the
# operator contacts prospects MANUALLY. The action list below is the whole surface.
# ===========================================================================

# Valid top-level actions for scripts/prospects.sh. NOTE: no "send"/"scrape"/"import".
# `assist` is the OPTIONAL, env-gated AI decision assist — it ADVISES the operator only
# (a lead score + a next step from a fixed allowlist); it still contacts no one.
PROSPECTS_ACTIONS="add list show update note followups analyze assist draft template status help"
# Valid pipeline statuses (mirrors engine/pipeline.js STATUSES).
PROSPECTS_STATUSES="new contacted in-talks won lost"
# Valid analysis engines (the SEO engine's engines, reused).
PROSPECTS_ENGINES="probe lighthouse"
# Valid draft-template kinds + languages (mirrors engine/templates.js).
PROSPECTS_TEMPLATES="intro followup audit-offer"
PROSPECTS_LANGS="en ar"
# Valid AI-assisted draft kinds (mirrors engine/drafts.js DRAFT_KINDS, friendly aliases).
PROSPECTS_DRAFT_KINDS="outreach referral content"
# Valid analysis DEPTHs — mirrors services/seo/engine/depth.js (the source of truth);
# duplicated here so an unknown value is rejected BEFORE Docker.
#   quick    rules-only, FREE, 0 AI calls
#   standard ~1 AI call (the existing single-call enrichment)
#   deep     full multi-specialist panel ≈ up to 7 AI calls
PROSPECTS_DEPTHS="quick standard deep"
# Hard cap on operator-supplied --competitor URLs per run. MIRRORS the MAX_COMPETITORS
# constant in services/seo/engine/competitors.js (the engine bound-checks too).
PROSPECTS_MAX_COMPETITORS=3

# Allowed status transitions, mirroring engine/pipeline.js TRANSITIONS. Used only
# for early, friendly validation in the shell; the engine is the source of truth.
prospects_transitions_for() {
  case "${1:-}" in
    new)      printf 'contacted lost' ;;
    contacted) printf 'in-talks won lost new' ;;
    in-talks) printf 'won lost contacted' ;;
    won)      printf 'in-talks' ;;
    lost)     printf 'new contacted' ;;
    *)        printf '' ;;
  esac
}

# Is "$1" a whitespace-separated member of "$2"?
prospects_contains() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

prospects_valid_action()   { prospects_contains "${1:-}" "${PROSPECTS_ACTIONS}"; }
prospects_valid_status()   { prospects_contains "${1:-}" "${PROSPECTS_STATUSES}"; }
prospects_valid_engine()   { prospects_contains "${1:-}" "${PROSPECTS_ENGINES}"; }
prospects_valid_template() { prospects_contains "${1:-}" "${PROSPECTS_TEMPLATES}"; }
prospects_valid_lang()     { prospects_contains "${1:-}" "${PROSPECTS_LANGS}"; }
prospects_valid_draft_kind() { prospects_contains "${1:-}" "${PROSPECTS_DRAFT_KINDS}"; }
prospects_valid_depth()    { prospects_contains "${1:-}" "${PROSPECTS_DEPTHS}"; }

# Is `to` a legal transition from `from`? (false for from==to or unknown statuses)
prospects_can_transition() {
  local from="${1:-}" to="${2:-}" allowed
  prospects_valid_status "${from}" || return 1
  prospects_valid_status "${to}"   || return 1
  [[ "${from}" == "${to}" ]] && return 1
  allowed="$(prospects_transitions_for "${from}")"
  prospects_contains "${to}" "${allowed}"
}

# Prospect id rule — identical to the SEO store / generator name rule.
prospects_valid_id() {
  [[ "${1:-}" =~ ^[a-z][a-z0-9-]{0,38}[a-z0-9]$ ]]
}

# A follow-up date must be a plain ISO calendar date YYYY-MM-DD (shape check only;
# the engine fully validates that the date exists).
prospects_valid_date() {
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

# A prospect's public URL must be an http(s) URL (the only thing analyze fetches).
prospects_valid_url() {
  [[ "${1:-}" =~ ^https?://[^[:space:]]+$ ]]
}

# Slugify a business name into an id candidate (mirrors engine/pipeline.js slugify;
# uniqueness is resolved by the engine/store). Lowercase, letter-first, [a-z0-9-].
prospects_slugify() {
  local s
  s="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-')"
  while [[ "${s}" == *--* ]]; do s="${s//--/-}"; done   # collapse runs
  s="${s#-}"; s="${s%-}"                    # trim leading/trailing hyphens
  while [[ -n "${s}" && "${s:0:1}" != [a-z] ]]; do s="${s:1}"; done  # id must start with a letter
  s="${s:0:40}"; s="${s%-}"
  printf '%s' "${s}"
}
