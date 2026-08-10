#!/usr/bin/env bash
# ===========================================================================
# pi-system — SEO helper, PURE LOGIC library (sourced by scripts/seo.sh)
# ---------------------------------------------------------------------------
# Side-effect-free shell functions: action/argument validation and parsing of the
# site list (services/seo/sites.example.conf -> data/seo/sites.conf). Kept apart
# from scripts/seo.sh so it can be unit-tested offline (tests/seo/run.sh) without
# Docker — exactly like scripts/lib/{ctl,bot,startup}-lib.sh.
# ===========================================================================

# Valid top-level actions for scripts/seo.sh.
SEO_ACTIONS="audit reaudit list trend recommend pdf content-ideas status help"
# Valid audit engines.
SEO_ENGINES="probe lighthouse"
# Valid analysis DEPTHs — the cost-vs-depth selector (engine/depth.js is the source of
# truth; this list is duplicated here so an unknown value is rejected BEFORE Docker).
#   quick    rules-only, FREE, 0 AI calls
#   standard ~1 AI call (the existing single-call enrichment)
#   deep     full multi-specialist panel ≈ up to 7 AI calls
SEO_DEPTHS="quick standard deep"
# Hard cap on operator-supplied --competitor URLs per run. MIRRORS the MAX_COMPETITORS
# constant in services/seo/engine/competitors.js (the engine bound-checks too; the
# helper checks BEFORE Docker so an over-cap typo never spends a container).
SEO_MAX_COMPETITORS=3

# Is "$1" a whitespace-separated member of "$2"?
seo_contains() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

seo_valid_action() { seo_contains "${1:-}" "${SEO_ACTIONS}"; }
seo_valid_engine() { seo_contains "${1:-}" "${SEO_ENGINES}"; }
seo_valid_depth()  { seo_contains "${1:-}" "${SEO_DEPTHS}"; }

# Shape check for an operator-pasted competitor URL: http or https, no whitespace.
# The SSRF guard (engine/ssrf-guard.js, called by the probe) does the real
# blocked/private/redirect/credential checks — this is the friendly "obvious typo"
# refusal that runs BEFORE Docker spins up.
seo_valid_url() {
  [[ "${1:-}" =~ ^https?://[^[:space:]]+$ ]]
}

# Project/site name rule — identical to the generator's project-name rule, so an
# audit's storage key can match a generated project's name.
seo_valid_name() {
  [[ "${1:-}" =~ ^[a-z][a-z0-9-]{0,38}[a-z0-9]$ ]]
}

# Resolve the sites-config path: $SEO_SITES_FILE wins, else the default under data/.
# Usage: seo_sites_file [project_root]
seo_sites_file() {
  local root="${1:-.}"
  if [[ -n "${SEO_SITES_FILE:-}" ]]; then
    printf '%s' "${SEO_SITES_FILE}"
  else
    printf '%s' "${root%/}/data/seo/sites.conf"
  fi
}

# Print normalized "name url" pairs from a sites file (comments/blanks stripped,
# names validated). Skips and warns (to stderr) on malformed lines. Returns 0 even
# when empty so callers decide what an empty list means.
seo_parse_sites() {
  local file="$1" name url rest
  [[ -f "${file}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"                       # strip trailing comments
    line="${line#"${line%%[![:space:]]*}"}"  # ltrim
    line="${line%"${line##*[![:space:]]}"}"  # rtrim
    [[ -z "${line}" ]] && continue
    # shellcheck disable=SC2086
    set -- ${line}
    name="${1:-}"; url="${2:-}"; rest="${3:-}"
    if [[ -z "${name}" || -z "${url}" || -n "${rest}" ]]; then
      printf '[seo-lib] skipping malformed line: %s\n' "${line}" >&2
      continue
    fi
    if ! seo_valid_name "${name}"; then
      printf '[seo-lib] skipping line with invalid name: %s\n' "${name}" >&2
      continue
    fi
    printf '%s %s\n' "${name}" "${url}"
  done <"${file}"
}

# Print just the site names from a sites file.
seo_list_names() {
  seo_parse_sites "$1" | awk '{print $1}'
}

# Look up a single site's URL by name; prints the URL and returns 0, or returns 1
# if the name is not present.
seo_lookup_url() {
  local file="$1" want="$2" name url
  while read -r name url; do
    if [[ "${name}" == "${want}" ]]; then printf '%s' "${url}"; return 0; fi
  done < <(seo_parse_sites "${file}")
  return 1
}
