#!/usr/bin/env bash
# ===========================================================================
# pi-system — new project generator (three-layer template system)
# ---------------------------------------------------------------------------
# Scaffolds a new client project into services/<name>/, pre-wired for this
# platform, from the THREE-LAYER template system under /templates:
#
#   base     -> the shared scaffold a project is built from
#               (dotnet-api | nextjs-app | fullstack)
#   modules  -> composable features layered on top (templates/modules/)
#   presets  -> sector recipes that pick a base + a set of modules
#               (clinic | ecommerce | company-site | real-estate)
#
# Pick EITHER a preset (which declares the base, db, locale and module list) OR
# a base shape directly (plus an optional explicit --modules list). Implemented
# modules are composed in; "planned" modules are SKIPPED gracefully and recorded
# as TODOs in the generated services/<name>/PROJECT.md, so a project is never
# left broken.
#
# Every generated project:
#   * Dockerized (multi-stage, ARM64), NO host ports — fronted by Caddy.
#   * Connected to a chosen database BY SERVICE NAME on the `internal` network,
#     using the SHARED credentials already in .env (nothing new to set for the DB).
#   * An env-driven Caddyfile block <subdomain>.${BASE_DOMAIN} -> <service>:<port>.
#   * A clearly-commented, EMPTY per-project section appended to .env.example.
#   * Bilingual-ready: a default locale (ar|en) + text direction are stamped in.
#
# Usage:
#   ./scripts/new-project.sh --name <name> \
#        ( --preset <preset> | --base <shape> [--modules <list>] ) \
#        [--db <engine>] [--subdomain <sub>] [--locale <ar|en>] [--force]
#
#     --name <name>      project/service name: lowercase letter first, then
#                        [a-z0-9-], 2-40 chars, no trailing hyphen.
#     --preset <p>       clinic | ecommerce | company-site | real-estate
#                        (declares base, db, locale and module list; each is
#                         overridable by the matching flag below).
#     --base <shape>     dotnet-api | nextjs-app | fullstack
#                        (--template is accepted as an alias for --base.)
#     --modules <list>   comma/space-separated module list. In preset mode these
#                        are ADDED to the preset's list (deduplicated).
#     --db <engine>      postgres | mysql | mongo | none
#     --subdomain <sub>  DNS label for the public subdomain (defaults to <name>)
#     --locale <ar|en>   default locale (RTL for ar). Defaults to ar (or the
#                        preset's declared locale).
#     --force            overwrite an existing services/<name> (it is first
#                        moved aside to services/<name>.bak-<timestamp>)
#     -h, --help         show this help and exit
#
# Missing required values are PROMPTED for when run interactively (a TTY);
# otherwise the script errors. Run from anywhere — paths resolve to project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[new-project]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

TEMPLATES_DIR="templates"
BASE_DIR="${TEMPLATES_DIR}/base"
MODULES_DIR="${TEMPLATES_DIR}/modules"
PRESETS_DIR="${TEMPLATES_DIR}/presets"
SERVICES_DIR="services"
ENV_EXAMPLE=".env.example"
ENV_FILE=".env"
CADDYFILE="services/proxy/Caddyfile"
BASE_COMPOSE="infrastructure/docker-compose.yml"
# Optional package-cache opt-in templates (copied in only with --cache).
CACHE_OPTIN_DIR="services/cache/optin"

VALID_BASES="dotnet-api nextjs-app fullstack"
VALID_DBS="postgres mysql mongo none"
VALID_LOCALES="ar en"

# Planned (documentation-only) modules — declared but NOT implemented. Requesting
# one scaffolds the base normally and records the module as a TODO in PROJECT.md.
# (All six feature modules — i18n-bilingual, content-admin, bookings, auth-sso,
#  whatsapp-integration and local-payments — have graduated to "implemented";
#  implemented modules are discovered from disk below, not listed here. The last two
#  still need EXTERNAL credentials to go LIVE, but ship with a working MOCK provider,
#  so they build/run now — their one-time credential steps are in each module's
#  SETUP.md. This list is empty until a new planned module is declared.)
PLANNED_MODULES=""

# One-line descriptions for the planned modules (used in PROJECT.md).
declare -A PLANNED_DESC=()
# Planned modules that need EXTERNAL merchant accounts / approved credentials.
declare -A PLANNED_CREDS=()

# --- Small helpers ---------------------------------------------------------
# Is "$1" a whitespace-separated member of "$2"?
contains() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# Read a "key: value" line from a manifest (first match), trimmed. Empty if absent.
manifest_get() { # manifest_get <file> <key>
  local file="$1" key="$2" line val
  line="$(grep -E "^[[:space:]]*${key}:[[:space:]]*" "${file}" 2>/dev/null | head -n1 || true)"
  [[ -z "${line}" ]] && { printf ''; return 0; }
  val="${line#*:}"
  val="${val#"${val%%[![:space:]]*}"}"   # ltrim
  val="${val%"${val##*[![:space:]]}"}"   # rtrim
  printf '%s' "${val}"
}

# Normalize a comma/space-separated list to space-separated, de-duplicated,
# order-preserving. Drops the literal token "none".
normalize_list() { # normalize_list "<raw>"
  local raw="${1//,/ }" tok out="" seen=" "
  for tok in ${raw}; do
    [[ "${tok}" == "none" ]] && continue
    case "${seen}" in *" ${tok} "*) ;; *) out+="${tok} "; seen+="${tok} " ;; esac
  done
  printf '%s' "${out% }"
}

usage() {
  cat >&2 <<EOF
Usage: ./scripts/new-project.sh --name <name> ( --preset <p> | --base <shape> [--modules <list>] ) [--db <engine>] [--subdomain <sub>] [--locale <ar|en>] [--force]

  --name <name>      lowercase, letter first, [a-z0-9-], 2-40 chars, no trailing '-'
  --preset <p>       ${VALID_PRESETS// / | }
  --base <shape>     ${VALID_BASES// / | }   (alias: --template)
  --modules <list>   comma/space-separated module list (added to a preset's list)
  --db <engine>      ${VALID_DBS// / | }
  --subdomain <sub>  DNS label for the public subdomain (default: <name>)
  --locale <ar|en>   default locale; ar => RTL (default: ar, or the preset's)
  --cache            write OPTIONAL local package-cache opt-in config into the
                     project (.npmrc -> Verdaccio, nuget.config -> BaGetter).
                     Non-breaking; needs ./scripts/cache.sh up to be useful.
  --force            overwrite an existing services/<name> (moved to a .bak dir first)
  -h, --help         show this help and exit

Modules — implemented: ${IMPLEMENTED_MODULES:-(none)}
          planned (skipped, recorded as TODO): ${PLANNED_MODULES:-(none)}

Examples:
  ./scripts/new-project.sh --name happy-teeth --preset clinic --subdomain teeth
  ./scripts/new-project.sh --name acme --base fullstack --db postgres --modules hello-module
EOF
}

# --- Discover implemented modules and available presets from disk ----------
IMPLEMENTED_MODULES=""
if [[ -d "${MODULES_DIR}" ]]; then
  for mf in "${MODULES_DIR}"/*/module.manifest; do
    [[ -e "${mf}" ]] || continue
    [[ "$(manifest_get "${mf}" status)" == "implemented" ]] || continue
    IMPLEMENTED_MODULES+="$(manifest_get "${mf}" name) "
  done
fi
IMPLEMENTED_MODULES="${IMPLEMENTED_MODULES% }"
KNOWN_MODULES="$(normalize_list "${IMPLEMENTED_MODULES} ${PLANNED_MODULES}")"

VALID_PRESETS=""
if [[ -d "${PRESETS_DIR}" ]]; then
  for pf in "${PRESETS_DIR}"/*/preset.manifest; do
    [[ -e "${pf}" ]] || continue
    VALID_PRESETS+="$(manifest_get "${pf}" name) "
  done
fi
VALID_PRESETS="${VALID_PRESETS% }"

# --- Parse arguments -------------------------------------------------------
NAME="" PRESET="" BASE="" MODULES_CLI="" DB="" SUBDOMAIN="" LOCALE="" FORCE=0 CACHE=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)        [[ $# -ge 2 ]] || { err "--name requires a value.";      usage; exit 1; }; NAME="$2";        shift 2 ;;
    --name=*)      NAME="${1#*=}";        shift ;;
    --preset)      [[ $# -ge 2 ]] || { err "--preset requires a value.";    usage; exit 1; }; PRESET="$2";      shift 2 ;;
    --preset=*)    PRESET="${1#*=}";      shift ;;
    --base|--template)     [[ $# -ge 2 ]] || { err "--base requires a value.";      usage; exit 1; }; BASE="$2"; shift 2 ;;
    --base=*|--template=*) BASE="${1#*=}"; shift ;;
    --modules)     [[ $# -ge 2 ]] || { err "--modules requires a value.";   usage; exit 1; }; MODULES_CLI="$2"; shift 2 ;;
    --modules=*)   MODULES_CLI="${1#*=}"; shift ;;
    --db)          [[ $# -ge 2 ]] || { err "--db requires a value.";        usage; exit 1; }; DB="$2";          shift 2 ;;
    --db=*)        DB="${1#*=}";          shift ;;
    --subdomain)   [[ $# -ge 2 ]] || { err "--subdomain requires a value."; usage; exit 1; }; SUBDOMAIN="$2";   shift 2 ;;
    --subdomain=*) SUBDOMAIN="${1#*=}";   shift ;;
    --locale)      [[ $# -ge 2 ]] || { err "--locale requires a value.";    usage; exit 1; }; LOCALE="$2";      shift 2 ;;
    --locale=*)    LOCALE="${1#*=}";      shift ;;
    --cache)       CACHE=1;               shift ;;
    -f|--force)    FORCE=1;               shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             err "Unknown argument: '$1'."; usage; exit 1 ;;
  esac
done

# --- Interactively fill missing required values (only when on a TTY) --------
prompt() {  # prompt <var-name> <question>
  local __var="$1" __q="$2" __ans=""
  if [[ -t 0 ]]; then
    read -r -p "${__q}: " __ans
    printf -v "${__var}" '%s' "${__ans}"
  fi
}
[[ -z "${NAME}" ]] && prompt NAME "Project name (e.g. acme-portal)"
# Choose a layer entry point: a preset, or a base shape directly.
if [[ -z "${PRESET}" && -z "${BASE}" ]]; then
  if [[ -t 0 ]]; then
    log "Pick a preset (${VALID_PRESETS// / / }) OR leave blank to choose a base shape."
    prompt PRESET "Preset (blank to skip)"
    [[ -z "${PRESET}" ]] && prompt BASE "Base shape (${VALID_BASES// / / })"
  fi
fi

# --- Resolve a preset (fills any value the CLI did not set) ----------------
PRESET_MODULES=""
if [[ -n "${PRESET}" ]]; then
  PRESET_MF="${PRESETS_DIR}/${PRESET}/preset.manifest"
  if [[ ! -f "${PRESET_MF}" ]]; then
    err "Unknown preset: '${PRESET}'. Valid: ${VALID_PRESETS:-<none>}."
    exit 1
  fi
  BASE="${BASE:-$(manifest_get "${PRESET_MF}" base)}"
  DB="${DB:-$(manifest_get "${PRESET_MF}" database)}"
  LOCALE="${LOCALE:-$(manifest_get "${PRESET_MF}" default_locale)}"
  PRESET_MODULES="$(manifest_get "${PRESET_MF}" modules)"
  log "Preset '${PRESET}': base=${BASE}, db=${DB}, locale=${LOCALE}, modules=[${PRESET_MODULES}]."
fi

# Prompt for a DB only in manual mode (a preset always supplies one).
[[ -z "${DB}" ]] && prompt DB "Database (${VALID_DBS// / / })"
[[ -z "${SUBDOMAIN}" ]] && prompt SUBDOMAIN "Subdomain (default: ${NAME:-<name>})"

# Defaults.
SUBDOMAIN="${SUBDOMAIN:-${NAME}}"
LOCALE="${LOCALE:-ar}"

# Final module list = preset's modules + any explicit --modules (deduplicated).
MODULES="$(normalize_list "${PRESET_MODULES} ${MODULES_CLI}")"

# --- Validate inputs -------------------------------------------------------
if [[ -z "${NAME}" || -z "${BASE}" || -z "${DB}" ]]; then
  err "Missing required value(s). Need --name, a --preset or --base, and --db."
  usage
  exit 1
fi

if ! [[ "${NAME}" =~ ^[a-z][a-z0-9-]{0,38}[a-z0-9]$ ]]; then
  err "Invalid project name: '${NAME}'."
  err "Use lowercase: start with a letter, then [a-z0-9-], 2-40 chars, no trailing '-'."
  exit 1
fi

if ! contains "${BASE}" "${VALID_BASES}"; then
  err "Unknown base shape: '${BASE}'. Valid: ${VALID_BASES}."
  exit 1
fi
if [[ ! -d "${BASE_DIR}/${BASE}" ]]; then
  err "Base template directory not found: ${BASE_DIR}/${BASE}"
  exit 1
fi

if ! contains "${DB}" "${VALID_DBS}"; then
  err "Unknown database engine: '${DB}'. Valid: ${VALID_DBS}."
  exit 1
fi

if ! contains "${LOCALE}" "${VALID_LOCALES}"; then
  err "Unknown locale: '${LOCALE}'. Valid: ${VALID_LOCALES}."
  exit 1
fi

if ! [[ "${SUBDOMAIN}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  err "Invalid subdomain: '${SUBDOMAIN}'. Must be a DNS label ([a-z0-9-], no leading/trailing '-')."
  exit 1
fi

# Every requested module must be known (implemented or planned).
for m in ${MODULES}; do
  if ! contains "${m}" "${KNOWN_MODULES}"; then
    err "Unknown module: '${m}'. Known modules: ${KNOWN_MODULES}."
    exit 1
  fi
done

# --- Derive substitution values -------------------------------------------
# Uppercased, every non-alphanumeric char -> '_', then a trailing '_' so it
# namespaces .env vars cleanly (e.g. acme-api -> ACME_API_ -> ACME_API_APP_SECRET).
NAME_UPPER="$(printf '%s' "${NAME}" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
ENVPREFIX="${NAME_UPPER}_"
GENERATED_DATE="$(date +%Y-%m-%d)"

# Text direction derived from the locale (Arabic is right-to-left).
case "${LOCALE}" in ar) DEFAULT_DIR="rtl" ;; *) DEFAULT_DIR="ltr" ;; esac

# Per-engine: service name (host), port, .NET connection string, URL form.
# The ${...} tokens are written LITERALLY into the YAML — Compose interpolates
# them at runtime from .env. Single quotes keep this shell from expanding them.
case "${DB}" in
  postgres)
    DB_HOST="postgres"; DB_PORT="5432"
    DB_CONNECTION_STRING='Host=postgres;Port=5432;Database=${POSTGRES_DB};Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}'
    DB_URL='postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@postgres:5432/${POSTGRES_DB}'
    ;;
  mysql)
    DB_HOST="mysql"; DB_PORT="3306"
    DB_CONNECTION_STRING='Server=mysql;Port=3306;Database=${MYSQL_DATABASE};User ID=${MYSQL_USER};Password=${MYSQL_PASSWORD}'
    DB_URL='mysql://${MYSQL_USER}:${MYSQL_PASSWORD}@mysql:3306/${MYSQL_DATABASE}'
    ;;
  mongo)
    DB_HOST="mongo"; DB_PORT="27017"
    DB_CONNECTION_STRING='mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@mongo:27017/${MONGO_INITDB_DATABASE}?authSource=admin'
    DB_URL='mongodb://${MONGO_INITDB_ROOT_USERNAME}:${MONGO_INITDB_ROOT_PASSWORD}@mongo:27017/${MONGO_INITDB_DATABASE}?authSource=admin'
    ;;
  none)
    DB_HOST="none"; DB_PORT=""
    DB_CONNECTION_STRING=""
    DB_URL=""
    ;;
esac

# Caddy upstream target depends on the base shape's web-facing service + port.
case "${BASE}" in
  dotnet-api)  PROXY_TARGET="${NAME}:8080" ;;
  nextjs-app)  PROXY_TARGET="${NAME}:3000" ;;
  fullstack)   PROXY_TARGET="${NAME}-web:3000" ;;
esac

# Placeholder -> value map. Values are substituted LITERALLY (no regex), so any
# characters in the connection strings (/, :, ;, $, {, }, @) are handled safely.
declare -A SUBS=(
  ["__PROJECT_NAME__"]="${NAME}"
  ["__SUBDOMAIN__"]="${SUBDOMAIN}"
  ["__DB_ENGINE__"]="${DB}"
  ["__DB_HOST__"]="${DB_HOST}"
  ["__DB_PORT__"]="${DB_PORT}"
  ["__DB_CONNECTION_STRING__"]="${DB_CONNECTION_STRING}"
  ["__DB_URL__"]="${DB_URL}"
  ["__ENVPREFIX__"]="${ENVPREFIX}"
  ["__DEFAULT_LOCALE__"]="${LOCALE}"
  ["__DEFAULT_DIR__"]="${DEFAULT_DIR}"
  ["__GENERATED_DATE__"]="${GENERATED_DATE}"
  ["__TEMPLATE__"]="${BASE}"
)

apply_subs() {  # apply_subs <file> — substitute placeholders in place
  local f="$1" content k
  content="$(cat -- "${f}")"
  for k in "${!SUBS[@]}"; do
    content="${content//"${k}"/${SUBS[${k}]}}"
  done
  printf '%s\n' "${content}" >"${f}"
}

render() {  # render <file> — print file content with placeholders substituted
  local content k
  content="$(cat -- "$1")"
  for k in "${!SUBS[@]}"; do
    content="${content//"${k}"/${SUBS[${k}]}}"
  done
  printf '%s' "${content}"
}

# --- Safety: do not clobber an existing project without --force -------------
TARGET="${SERVICES_DIR}/${NAME}"
if [[ -e "${TARGET}" ]]; then
  if [[ "${FORCE}" -ne 1 ]]; then
    err "${TARGET} already exists. Refusing to overwrite."
    err "Pass --force to regenerate (the existing folder is moved to a .bak dir first)."
    exit 1
  fi
  BACKUP="${TARGET}.bak-$(date +%Y%m%d-%H%M%S)"
  mv "${TARGET}" "${BACKUP}"
  warn "Existing ${TARGET} moved to ${BACKUP} (delete it once you're sure)."
fi

# --- Copy the base shape and substitute placeholders -----------------------
log "Scaffolding '${NAME}' from base '${BASE}' (locale=${LOCALE}/${DEFAULT_DIR}) ..."
mkdir -p "${SERVICES_DIR}"
cp -R "${BASE_DIR}/${BASE}" "${TARGET}"

# Rename the base compose fragment to <name>.compose.yml (the project's main fragment).
mv "${TARGET}/service.compose.yml" "${TARGET}/${NAME}.compose.yml"

# Substitute in every regular file of the new project.
while IFS= read -r -d '' f; do
  apply_subs "${f}"
done < <(find "${TARGET}" -type f -print0)

log "Created ${TARGET}/ (main compose: ${NAME}.compose.yml)."

# --- Compose the modules ---------------------------------------------------
# Implemented modules are wired in; planned modules are skipped + recorded as
# TODOs so the project is never left broken.
ACTIVE_NAMES=() ACTIVE_DESCS=()
TODO_NAMES=() TODO_DESCS=() TODO_CREDS=()
NA_NAMES=() NA_DESCS=() NA_BASES=()  # implemented but incompatible with this base
MODULE_ENV_LINES=()        # appended to the project's .env.example section
CADDY_ROUTE_LINES=()       # injected into the project's Caddy site block
MODULE_FRAGMENTS=()        # extra compose fragments created next to the main one

for m in ${MODULES}; do
  if contains "${m}" "${IMPLEMENTED_MODULES}"; then
    mdir="${MODULES_DIR}/${m}"
    mf="${mdir}/module.manifest"
    mdesc="$(manifest_get "${mf}" description)"
    mbasecompat="$(manifest_get "${mf}" base_compatible)"

    # Honour the module's declared base compatibility (an existing contract field).
    # A module that does not support this base is SKIPPED cleanly and recorded in
    # PROJECT.md — e.g. a frontend-only module (i18n) on a dotnet-api base, which
    # instead gets the module's backend guidance — never composed incorrectly.
    if [[ -n "${mbasecompat}" && "${mbasecompat}" != "all" ]] \
       && ! contains "${BASE}" "$(normalize_list "${mbasecompat}")"; then
      NA_NAMES+=("${m}"); NA_DESCS+=("${mdesc}"); NA_BASES+=("${mbasecompat}")
      warn "  ~ module '${m}' does not support base '${BASE}' (supports: ${mbasecompat}) — skipped; recorded in PROJECT.md."
      continue
    fi

    menv="$(manifest_get "${mf}" env)"
    mfiles="$(manifest_get "${mf}" files)"
    mcompose="$(manifest_get "${mf}" compose)"
    mcaddy="$(manifest_get "${mf}" caddy_routes)"
    mcreds="$(manifest_get "${mf}" external_credentials)"

    ACTIVE_NAMES+=("${m}"); ACTIVE_DESCS+=("${mdesc}")
    log "  + module '${m}' (implemented) — composing in."

    # Env templates (empty), labelled with the module name.
    if [[ -n "${menv}" && "${menv}" != "none" ]]; then
      MODULE_ENV_LINES+=("" "# (module: ${m}) — empty templates; set in .env if used.")
      for v in $(normalize_list "${menv}"); do MODULE_ENV_LINES+=("${v}="); done
    fi

    # Source files -> copied into the project, placeholders substituted. This is
    # how an IN-APP module (e.g. i18n) layers code onto the base. A base-specific
    # subtree (files/<base>/) overrides the generic files/ tree, so each base gets
    # its code at the right path (nextjs-app at the app root; fullstack under
    # frontend/). Module files obey the same hard rules as the base they extend.
    if [[ -n "${mfiles}" && "${mfiles}" != "none" ]]; then
      srcroot="${mdir}/${mfiles}"
      [[ -d "${srcroot}/${BASE}" ]] && srcroot="${srcroot}/${BASE}"
      if [[ -d "${srcroot}" ]]; then
        fcount=0
        while IFS= read -r -d '' sf; do
          rel="${sf#"${srcroot}/"}"
          dest="${TARGET}/${rel}"
          mkdir -p "$(dirname "${dest}")"
          cp "${sf}" "${dest}"
          apply_subs "${dest}"
          fcount=$((fcount + 1))
        done < <(find "${srcroot}" -type f -print0)
        log "    files -> copied ${fcount} file(s) into services/${NAME}/ (base '${BASE}')."
      else
        warn "    module '${m}' declares files '${mfiles}' but no tree for base '${BASE}' — skipped."
      fi
    fi

    # Compose fragment -> services/<name>/<name>.<module>.compose.yml (project.sh loads it).
    # `compose:` may name EITHER a single base-agnostic file (e.g. content-admin's
    # service.compose.yml, which ships its own standalone container) OR a DIRECTORY
    # of per-base fragments — the same per-base idea as files/<base>/ above. When it
    # is a directory the generator picks <dir>/<base>.compose.yml, so a module that
    # must MERGE config into the base's OWN service(s) — whose names differ by shape
    # (<name> vs <name>-api / <name>-web) — can ship the right fragment per base
    # (e.g. auth-sso, which adds OIDC env to the existing services). A directory with
    # no fragment for this base is skipped cleanly (the base scaffold stays valid).
    if [[ -n "${mcompose}" && "${mcompose}" != "none" ]]; then
      csrc="${mdir}/${mcompose}"
      [[ -d "${csrc}" ]] && csrc="${csrc}/${BASE}.compose.yml"
      if [[ -f "${csrc}" ]]; then
        dest="${TARGET}/${NAME}.${m}.compose.yml"
        cp "${csrc}" "${dest}"
        apply_subs "${dest}"
        MODULE_FRAGMENTS+=("${dest}")
        log "    compose fragment -> ${dest}"
      else
        warn "    module '${m}' declares compose '${mcompose}' but no fragment for base '${BASE}' — skipped."
      fi
    fi

    # Caddy routes -> injected into this project's site block (no new host ports).
    if [[ -n "${mcaddy}" && "${mcaddy}" != "none" ]]; then
      if [[ -f "${mdir}/${mcaddy}" ]]; then
        CADDY_ROUTE_LINES+=("$(printf '\t# routes added by module: %s' "${m}")")
        while IFS= read -r line; do CADDY_ROUTE_LINES+=("${line}"); done < <(render "${mdir}/${mcaddy}")
      else
        warn "    module '${m}' declares caddy_routes '${mcaddy}' but the file is missing — skipped."
      fi
    fi
  else
    # Planned (or otherwise not implemented): skip gracefully, record a TODO.
    TODO_NAMES+=("${m}"); TODO_DESCS+=("${PLANNED_DESC[${m}]:-Planned module.}")
    TODO_CREDS+=("${PLANNED_CREDS[${m}]:-}")
    warn "  - module '${m}' (planned) — skipped; recorded as a TODO in PROJECT.md."
  fi
done

# --- Optional: package-cache opt-in config (--cache) -----------------------
# Writes the opt-in files from services/cache/optin into the project so its
# installs use the LOCAL npm/NuGet cache when it is running. OPTIONAL and
# non-breaking (default off); keeps the same no-overwrite-without-force safety.
# Placed per base: nextjs-app -> .npmrc at root; dotnet-api -> nuget.config at
# root; fullstack -> frontend/.npmrc + backend/nuget.config.
CACHE_OPTIN_FILES=()
write_optin() {  # write_optin <src-basename> <dest-relative-to-project>
  local src="${CACHE_OPTIN_DIR}/$1" dest="${TARGET}/$2"
  if [[ ! -f "${src}" ]]; then
    warn "  cache opt-in source missing: ${src} — skipped."
    return 0
  fi
  if [[ -e "${dest}" && "${FORCE}" -ne 1 ]]; then
    warn "  ${dest} already exists — left unchanged (use --force to overwrite)."
    return 0
  fi
  mkdir -p "$(dirname "${dest}")"
  cp "${src}" "${dest}"               # no placeholders to substitute
  CACHE_OPTIN_FILES+=("$2")
  log "  + cache opt-in: ${dest}"
}
if [[ "${CACHE}" -eq 1 ]]; then
  log "Writing package-cache opt-in config (--cache) ..."
  case "${BASE}" in
    dotnet-api) write_optin "nuget.config" "nuget.config" ;;
    nextjs-app) write_optin ".npmrc" ".npmrc" ;;
    fullstack)
      write_optin ".npmrc" "frontend/.npmrc"
      write_optin "nuget.config" "backend/nuget.config"
      ;;
  esac
  if ((${#CACHE_OPTIN_FILES[@]})); then
    log "  Project will use the local cache when it is up + reachable (internal network)."
    warn "  Start it with ./scripts/cache.sh up; delete the file(s) to use public registries."
  fi
fi

# --- Append the Caddy site block (idempotent) ------------------------------
CADDY_BEGIN=">>> pi-system project: ${NAME} >>>"
if [[ ! -f "${CADDYFILE}" ]]; then
  warn "Caddyfile not found at ${CADDYFILE}; skipping the proxy block. Add manually:"
  warn "  ${SUBDOMAIN}.{\$BASE_DOMAIN:localhost} { tls {\$CADDY_TLS:internal}; reverse_proxy ${PROXY_TARGET} }"
elif grep -qF "${CADDY_BEGIN}" "${CADDYFILE}"; then
  warn "Caddyfile already has a block for '${NAME}' — leaving it unchanged."
else
  {
    printf '\n# %s\n' "${CADDY_BEGIN}"
    printf '# Generated %s by scripts/new-project.sh for project "%s".\n' "${GENERATED_DATE}" "${NAME}"
    printf '%s.{$BASE_DOMAIN:localhost} {\n' "${SUBDOMAIN}"
    printf '\ttls {$CADDY_TLS:internal}\n'
    printf '\tencode zstd gzip\n'
    # Module path routes (if any) come BEFORE the catch-all reverse_proxy.
    if ((${#CADDY_ROUTE_LINES[@]})); then
      printf '%s\n' "${CADDY_ROUTE_LINES[@]}"
    fi
    printf '\treverse_proxy %s\n' "${PROXY_TARGET}"
    printf '}\n'
    printf '# <<< pi-system project: %s <<<\n' "${NAME}"
  } >>"${CADDYFILE}"
  log "Appended Caddy block: ${SUBDOMAIN}.\${BASE_DOMAIN} -> ${PROXY_TARGET}"
fi

# --- Append the per-project .env.example section (idempotent, empty only) ---
ENV_BEGIN="# >>> PROJECT: ${NAME} >>>"
if grep -qF "${ENV_BEGIN}" "${ENV_EXAMPLE}" 2>/dev/null; then
  warn "${ENV_EXAMPLE} already has a section for '${NAME}' — leaving it unchanged."
else
  {
    printf '\n# ---------------------------------------------------------------------------\n'
    printf '%s\n' "${ENV_BEGIN}"
    printf '# Project "%s" (base: %s, db: %s, locale: %s) — added %s by scripts/new-project.sh.\n' \
      "${NAME}" "${BASE}" "${DB}" "${LOCALE}" "${GENERATED_DATE}"
    printf '# Reached via Caddy at %s.${BASE_DOMAIN}. Empty templates only — set real\n' "${SUBDOMAIN}"
    printf '# values in .env (never commit them). The DB connection is built from the\n'
    printf '# shared DB credentials above; these vars are this project'\''s own.\n'
    printf '#\n'
    printf '# App secret (token signing / data protection, etc.). Use a strong random value.\n'
    printf '%sAPP_SECRET=\n' "${ENVPREFIX}"
    printf '# OIDC client for putting this project behind Keycloak (auth.${BASE_DOMAIN}).\n'
    printf '# Create a confidential client in your realm and paste its ID + secret here.\n'
    printf '%sOIDC_CLIENT_ID=\n' "${ENVPREFIX}"
    printf '%sOIDC_CLIENT_SECRET=\n' "${ENVPREFIX}"
    # Env templates contributed by composed (implemented) modules.
    if ((${#MODULE_ENV_LINES[@]})); then
      printf '%s\n' "${MODULE_ENV_LINES[@]}"
    fi
    printf '# <<< PROJECT: %s <<<\n' "${NAME}"
  } >>"${ENV_EXAMPLE}"
  log "Appended an empty PROJECT section to ${ENV_EXAMPLE} (prefix ${ENVPREFIX})."
fi

# --- Generate services/<name>/PROJECT.md (summary + module TODO list) ------
DOMAIN="$(grep -E '^BASE_DOMAIN=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2- || true)"
DOMAIN="${DOMAIN:-localhost}"
PROJECT_MD="${TARGET}/PROJECT.md"
pm() { printf '%s\n' "$*" >>"${PROJECT_MD}"; }
: >"${PROJECT_MD}"
pm "# ${NAME} — project manifest"
pm ""
pm "Generated ${GENERATED_DATE} by \`scripts/new-project.sh\`."
pm ""
pm "| Setting        | Value |"
pm "| -------------- | ----- |"
pm "| Base shape     | \`${BASE}\` |"
[[ -n "${PRESET}" ]] && pm "| Preset         | \`${PRESET}\` |"
pm "| Database       | \`${DB}\` |"
pm "| Default locale | \`${LOCALE}\` (dir: \`${DEFAULT_DIR}\`) |"
pm "| Subdomain      | \`${SUBDOMAIN}.${DOMAIN}\` |"
pm "| Main compose   | \`${NAME}.compose.yml\` |"
pm ""
pm "Reached only via Caddy at **https://${SUBDOMAIN}.${DOMAIN}** — no host ports."
pm ""

pm "## Active modules"
pm ""
if ((${#ACTIVE_NAMES[@]})); then
  for i in "${!ACTIVE_NAMES[@]}"; do
    pm "- \`${ACTIVE_NAMES[$i]}\` — ${ACTIVE_DESCS[$i]}"
  done
else
  pm "_None — this project is the base shape only._"
fi
pm ""

pm "## Planned modules — TODO"
pm ""
if ((${#TODO_NAMES[@]})); then
  pm "These modules were requested but are **not implemented yet**, so they were"
  pm "skipped. The base scaffold is fully functional without them. Each becomes"
  pm "active automatically once the module exists — just re-run the generator (or"
  pm "add it with \`--modules\`) after it is implemented."
  pm ""
  for i in "${!TODO_NAMES[@]}"; do
    pm "- [ ] \`${TODO_NAMES[$i]}\` — ${TODO_DESCS[$i]}"
    if [[ -n "${TODO_CREDS[$i]}" ]]; then
      pm "  - ⚠ **Requires external credentials:** ${TODO_CREDS[$i]}. This needs real-world"
      pm "    onboarding (a merchant/business account + approved API keys), not just code."
    fi
  done
else
  pm "_None._"
fi
pm ""

pm "## Modules not applied (incompatible base)"
pm ""
if ((${#NA_NAMES[@]})); then
  pm "These modules were requested but do **not support the \`${BASE}\` base**, so"
  pm "they were skipped. The base scaffold is fully functional without them — see"
  pm "each module's README for the alternative it offers for this base."
  pm ""
  for i in "${!NA_NAMES[@]}"; do
    pm "- \`${NA_NAMES[$i]}\` — ${NA_DESCS[$i]}"
    pm "  - Supports bases: \`${NA_BASES[$i]}\`. For \`${BASE}\`, see"
    pm "    \`templates/modules/${NA_NAMES[$i]}/README.md\` (e.g. its optional backend guidance)."
  done
else
  pm "_None._"
fi
pm ""

if [[ "${CACHE}" -eq 1 ]]; then
  pm "## Package cache"
  pm ""
  if ((${#CACHE_OPTIN_FILES[@]})); then
    pm "This project opted into the local package cache (\`--cache\`). These file(s)"
    pm "point installs at the cache (Verdaccio / BaGetter) when it is running and"
    pm "reachable on the \`internal\` network:"
    pm ""
    for f in "${CACHE_OPTIN_FILES[@]}"; do pm "- \`${f}\`"; done
    pm ""
    pm "Start the cache with \`./scripts/cache.sh up\`. To fall back to the public"
    pm "registries, delete the file(s). See docs/README.md \"Package cache\" — incl."
    pm "the build-network note for using the cache during \`docker compose build\`."
  else
    pm "\`--cache\` was requested but no opt-in file was written (already present, or"
    pm "the templates in \`services/cache/optin\` are missing)."
  fi
  pm ""
fi

pm "## Next steps"
pm ""
if [[ "${DB}" != "none" ]]; then
  pm "1. Start its database:   \`./scripts/db.sh ${DB} up\`"
else
  pm "1. (No database selected.)"
fi
pm "2. Ensure Caddy is up:   \`./scripts/start-proxy.sh\`"
pm "3. Build + start it:      \`./scripts/project.sh up ${NAME}\`"
pm "4. Open it:               https://${SUBDOMAIN}.${DOMAIN}"
pm ""
pm "Fill this project's secrets in \`.env\` (copy the \`PROJECT: ${NAME}\` section"
pm "from \`.env.example\` and set values; they are optional until used)."
log "Wrote ${PROJECT_MD}."

# --- Validate the merged compose (best-effort) -----------------------------
if [[ -f "${ENV_FILE}" ]] && docker compose version >/dev/null 2>&1; then
  CONFIG_ARGS=(--env-file "${ENV_FILE}" --project-directory "${PROJECT_ROOT}" -f "${BASE_COMPOSE}" -f "${TARGET}/${NAME}.compose.yml")
  if ((${#MODULE_FRAGMENTS[@]})); then
    for frag in "${MODULE_FRAGMENTS[@]}"; do CONFIG_ARGS+=(-f "${frag}"); done
  fi
  if docker compose "${CONFIG_ARGS[@]}" config -q; then
    log "Compose configuration validates."
  else
    warn "Compose validation reported issues — review ${TARGET}/${NAME}.compose.yml."
  fi
else
  log "Skipped compose validation (need both a .env and Docker Compose v2)."
fi

# --- Next steps ------------------------------------------------------------
ENV_LABEL="${ENV_BEGIN#"# "}"   # the section marker without the leading "# "

echo
log "Project '${NAME}' scaffolded (base: ${BASE}${PRESET:+, preset: ${PRESET}})."
if ((${#ACTIVE_NAMES[@]})); then
  log "Active modules: ${ACTIVE_NAMES[*]}"
fi
if ((${#TODO_NAMES[@]})); then
  warn "Planned modules skipped (see ${PROJECT_MD}): ${TODO_NAMES[*]}"
  for i in "${!TODO_NAMES[@]}"; do
    [[ -n "${TODO_CREDS[$i]}" ]] && warn "  '${TODO_NAMES[$i]}' needs external credentials: ${TODO_CREDS[$i]}"
  done
fi
if ((${#NA_NAMES[@]})); then
  warn "Modules not applied to base '${BASE}' (see ${PROJECT_MD}): ${NA_NAMES[*]}"
fi
echo
log "Next steps:"
if [[ "${DB}" != "none" ]]; then
  printf '   1. Start its database:   ./scripts/db.sh %s up\n' "${DB}"
else
  printf '   1. (No database selected.)\n'
fi
cat <<EOF
   2. Ensure Caddy is up:    ./scripts/start-proxy.sh
                             (it re-reads the Caddyfile and picks up the new block)
   3. Build + start it:      ./scripts/project.sh up ${NAME}
   4. Open it:               https://${SUBDOMAIN}.${DOMAIN}

   Project summary + module TODOs:  ${PROJECT_MD}
   Fill the project's secrets in .env (copy the new "${ENV_LABEL}" section
   from ${ENV_EXAMPLE} into .env and set values; they are optional until used).
EOF
warn "If Caddy was already running, reload it to serve the new subdomain:"
warn "  docker exec ${COMPOSE_PROJECT_NAME:-pi-system}_caddy caddy reload --config /etc/caddy/Caddyfile"
warn "  (or just re-run ./scripts/start-proxy.sh)"
