#!/usr/bin/env bash
# ===========================================================================
# pi-system — lightweight quality gate for a generated project
# ---------------------------------------------------------------------------
# Runs static analysis / linting, the relevant compiler+analyzer checks, and a
# dependency vulnerability scan against ONE generated project (services/<name>),
# prints a clear PASS/FAIL per check, and EXITS NON-ZERO on any failure — so it
# can act as a gate before you build and deploy.
#
# Pi-aware by design (see services/quality/README.md):
#   * No SonarQube / no heavy always-on analyser — only lightweight, ARM64-native
#     tooling that ships with the stacks the platform targets (.NET, Next.js).
#   * Checks run STRICTLY SEQUENTIALLY (never in parallel) so at most one SDK
#     container is alive at a time — peak RAM stays bounded on the Pi 5.
#   * Each check runs in a throwaway, pinned, ARM64 SDK container
#     (mcr.microsoft.com/dotnet/sdk:10.0, node:22-alpine — the SAME images the
#     templates build from). Nothing is left running afterwards.
#   * Your project is mounted READ-ONLY and copied into a disposable in-container
#     working dir, so a run never leaves node_modules/ obj/ bin/ or a lockfile
#     behind in services/<name>.
#
# Usage:
#     ./scripts/quality.sh <name>
#
#   <name>   the generated project to check (a directory under services/).
#
# Examples:
#     ./scripts/quality.sh happy-teeth
#
# Optional env knobs (also documented in the QUALITY GATE section of .env.example):
#     QUALITY_DOTNET_WARN_AS_ERROR   true|false  (default true)
#     QUALITY_NPM_AUDIT_LEVEL        low|moderate|high|critical (default high)
#
# Run from anywhere — paths resolve relative to the project root.
# ===========================================================================
set -euo pipefail

# --- Resolve project root (the parent of this scripts/ directory) ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_ROOT}"

# --- Tiny coloured loggers -------------------------------------------------
log()  { printf '\033[0;32m[quality]\033[0m %s\n' "$*"; }
warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; }

# --- Pinned, ARM64 tool images + tool versions (NEVER "latest") ------------
DOTNET_SDK_IMAGE="mcr.microsoft.com/dotnet/sdk:10.0"   # matches templates/base/dotnet-api
NODE_IMAGE="node:22-alpine"                            # matches templates/base/nextjs-app
ESLINT_PIN="8.57.1"                                    # pinned ESLint (fallback lint)
ESLINT_CONFIG_NEXT_PIN="15.5.18"                       # pinned eslint-config-next (matches next)

# --- Tunable gate behaviour (env, with sane defaults) ----------------------
DOTNET_WARN_AS_ERROR="${QUALITY_DOTNET_WARN_AS_ERROR:-true}"
NPM_AUDIT_LEVEL="${QUALITY_NPM_AUDIT_LEVEL:-high}"

usage() {
  cat >&2 <<EOF
Usage: ./scripts/quality.sh <name>

  <name>   the generated project to check (a directory under services/).

Runs (per detected stack), sequentially, in pinned ARM64 SDK containers:
  .NET   : dotnet restore; dotnet build (warnings-as-errors, Roslyn analyzers);
           dotnet format --verify-no-changes; dotnet list package --vulnerable
  Next.js: npm ci; ESLint (npm run lint, or pinned 'next lint'); npm audit

Prints PASS/FAIL per check; exits non-zero if ANY check fails.

Optional env: QUALITY_DOTNET_WARN_AS_ERROR=true|false (default true)
              QUALITY_NPM_AUDIT_LEVEL=low|moderate|high|critical (default high)

Examples:
  ./scripts/quality.sh happy-teeth
EOF
}

# --- Validate arguments ----------------------------------------------------
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [[ $# -ne 1 ]]; then
  err "Expected exactly 1 argument (the project name), got $#."
  usage
  exit 1
fi
NAME="$1"

if [[ ! "${NAME}" =~ ^[a-z][a-z0-9-]{0,38}[a-z0-9]$ ]]; then
  err "Invalid project name: '${NAME}'."
  err "Expected a generated project's name (lowercase, letter first, [a-z0-9-])."
  exit 1
fi

TARGET="services/${NAME}"
ABS="${PROJECT_ROOT}/${TARGET}"
if [[ ! -d "${ABS}" ]]; then
  err "No such project: ${TARGET}"
  err "Generate one first, e.g.: ./scripts/new-project.sh --name ${NAME} --preset clinic"
  exit 1
fi
if [[ "${DOTNET_WARN_AS_ERROR}" != "true" && "${DOTNET_WARN_AS_ERROR}" != "false" ]]; then
  err "QUALITY_DOTNET_WARN_AS_ERROR must be 'true' or 'false' (got '${DOTNET_WARN_AS_ERROR}')."
  exit 1
fi

# --- Preconditions ---------------------------------------------------------
if ! docker version >/dev/null 2>&1; then
  err "Docker is not available. The quality gate runs its checks in containers."
  err "Install/start Docker (see ./scripts/setup.sh) and try again."
  exit 1
fi

# --- Detect which stacks live in the project -------------------------------
# DOTNET_DIRS / NODE_DIRS are project-relative directories (root = ".").
# (A fullstack project yields e.g. "backend" for .NET and "frontend" for Node.)
# -printf '%h' gives each match's directory; make it project-relative (root = ".").
mapfile -t DOTNET_DIRS < <(
  find "${ABS}" -type f -name '*.csproj' \
    -not -path '*/bin/*' -not -path '*/obj/*' -printf '%h\n' 2>/dev/null \
  | sed "s#^${ABS}/##; s#^${ABS}\$#.#" | sort -u
)
mapfile -t NODE_DIRS < <(
  find "${ABS}" -type f -name 'package.json' \
    -not -path '*/node_modules/*' -printf '%h\n' 2>/dev/null \
  | sed "s#^${ABS}/##; s#^${ABS}\$#.#" | sort -u
)

if [[ ${#DOTNET_DIRS[@]} -eq 0 && ${#NODE_DIRS[@]} -eq 0 ]]; then
  err "No .NET (*.csproj) or Node (package.json) projects found under ${TARGET}."
  err "Nothing to check."
  exit 1
fi

log "Quality gate for '${NAME}':"
[[ ${#DOTNET_DIRS[@]} -gt 0 ]] && log "  .NET project(s):    ${DOTNET_DIRS[*]}"
[[ ${#NODE_DIRS[@]}  -gt 0 ]] && log "  Next.js/JS project(s): ${NODE_DIRS[*]}"
log "  Checks run sequentially in pinned ARM64 SDK containers (gentle on the Pi)."

# --- Inner check scripts (fed to the container via stdin: sh -s) -----------
# Quoted heredocs => NO host expansion; arguments are passed positionally so the
# container does the work and we never wrestle with nested quoting.
DOTNET_SCRIPT="$(mktemp)"
NODE_SCRIPT="$(mktemp)"
RESULTS_FILE="$(mktemp)"
cleanup() { rm -f "${DOTNET_SCRIPT}" "${NODE_SCRIPT}" "${RESULTS_FILE}"; }
trap cleanup EXIT

cat >"${DOTNET_SCRIPT}" <<'EOS'
# args: $1 = subdir (project-relative), $2 = warn-as-error (true|false)
set -u
SUBDIR="$1"; WARN="$2"
emit() { printf 'PI_QG|%s|%s\n' "$1" "$2"; }
note() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
overall=0

note "Preparing an isolated copy (your project is mounted read-only)"
mkdir -p /work && cp -a /src/. /work/ || { echo "failed to copy project"; exit 3; }
cd "/work/${SUBDIR}" || { echo "subdir not found: ${SUBDIR}"; exit 3; }

note "dotnet restore"
if dotnet restore; then emit "[.NET ${SUBDIR}] restore" PASS
else emit "[.NET ${SUBDIR}] restore" FAIL; overall=1; fi

note "Static analysis — dotnet build (warnings-as-errors=${WARN}, Roslyn analyzers)"
if dotnet build -c Release --no-restore \
     -p:TreatWarningsAsErrors="${WARN}" \
     -p:EnableNETAnalyzers=true \
     -p:AnalysisMode=Recommended; then
  emit "[.NET ${SUBDIR}] analyze (build)" PASS
else
  emit "[.NET ${SUBDIR}] analyze (build)" FAIL; overall=1
fi

note "Lint / format — dotnet format --verify-no-changes"
if dotnet format --verify-no-changes --no-restore; then
  emit "[.NET ${SUBDIR}] format" PASS
else
  emit "[.NET ${SUBDIR}] format" FAIL; overall=1
fi

note "Dependency audit — dotnet list package --vulnerable"
vout="$(dotnet list package --vulnerable --include-transitive 2>&1)"
printf '%s\n' "${vout}"
if printf '%s\n' "${vout}" | grep -q "has the following vulnerable packages"; then
  emit "[.NET ${SUBDIR}] audit (vulnerable pkgs)" FAIL; overall=1
else
  emit "[.NET ${SUBDIR}] audit (vulnerable pkgs)" PASS
fi

exit "${overall}"
EOS

cat >"${NODE_SCRIPT}" <<'EOS'
# args: $1 = subdir, $2 = npm audit level, $3 = eslint pin, $4 = eslint-config-next pin
set -u
SUBDIR="$1"; AUDIT_LEVEL="$2"; ESLINT_PIN="$3"; ECN_PIN="$4"
emit() { printf 'PI_QG|%s|%s\n' "$1" "$2"; }
note() { printf '\n\033[1;36m==> %s\033[0m\n' "$1"; }
overall=0

note "Preparing an isolated copy (your project is mounted read-only)"
mkdir -p /work && cp -a /src/. /work/ || { echo "failed to copy project"; exit 3; }
cd "/work/${SUBDIR}" || { echo "subdir not found: ${SUBDIR}"; exit 3; }

note "Install dependencies (npm ci, or npm install if there is no lockfile)"
if npm ci || npm install; then emit "[Next.js ${SUBDIR}] install" PASS
else emit "[Next.js ${SUBDIR}] install" FAIL; overall=1; fi

note "Lint / static analysis — ESLint"
if node -e "process.exit(((require('./package.json').scripts)||{}).lint?0:1)" 2>/dev/null; then
  # The project defines its own lint script — respect it.
  if npm run lint; then emit "[Next.js ${SUBDIR}] lint (npm run lint)" PASS
  else emit "[Next.js ${SUBDIR}] lint (npm run lint)" FAIL; overall=1; fi
else
  # No lint config in the project: set up a PINNED ESLint + Next config in this
  # throwaway copy only (the project on disk is untouched) and run `next lint`.
  if [ ! -f .eslintrc.json ] && [ ! -f .eslintrc.js ] && [ ! -f .eslintrc.cjs ] \
     && [ ! -f .eslintrc ] && [ ! -f .eslintrc.yml ] && [ ! -f .eslintrc.yaml ] \
     && [ ! -f eslint.config.js ] && [ ! -f eslint.config.mjs ] && [ ! -f eslint.config.cjs ]; then
    printf '{ "extends": "next/core-web-vitals" }\n' > .eslintrc.json
  fi
  if npm install --no-save "eslint@${ESLINT_PIN}" "eslint-config-next@${ECN_PIN}" \
     && npx --no-install next lint; then
    emit "[Next.js ${SUBDIR}] lint (next lint)" PASS
  else
    emit "[Next.js ${SUBDIR}] lint (next lint)" FAIL; overall=1
  fi
fi

note "Dependency audit — npm audit --audit-level=${AUDIT_LEVEL}"
if npm audit --audit-level="${AUDIT_LEVEL}"; then
  emit "[Next.js ${SUBDIR}] audit (npm audit)" PASS
else
  emit "[Next.js ${SUBDIR}] audit (npm audit)" FAIL; overall=1
fi

exit "${overall}"
EOS

GATE_FAIL=0

# run_stack <image> <script-file> <subdir> <arg2> [arg3] [arg4]
# Streams the container's output live AND captures the PI_QG result markers.
run_stack() {
  local image="$1" scriptfile="$2"; shift 2
  local tmp; tmp="$(mktemp)"
  local rc
  set +e
  docker run --rm -i -v "${ABS}:/src:ro" -w /work "${image}" \
    sh -s "$@" <"${scriptfile}" 2>&1 | tee "${tmp}"
  rc=${PIPESTATUS[0]}
  set -e
  grep '^PI_QG|' "${tmp}" >>"${RESULTS_FILE}" || true
  rm -f "${tmp}"
  if [[ "${rc}" -ne 0 ]]; then GATE_FAIL=1; fi
  return 0
}

# --- Run .NET checks, then Next.js checks — one container at a time ---------
for d in "${DOTNET_DIRS[@]}"; do
  log "── .NET checks (${d}) ───────────────────────────────────────────────"
  run_stack "${DOTNET_SDK_IMAGE}" "${DOTNET_SCRIPT}" "${d}" "${DOTNET_WARN_AS_ERROR}"
done
for d in "${NODE_DIRS[@]}"; do
  log "── Next.js / JS checks (${d}) ───────────────────────────────────────"
  run_stack "${NODE_IMAGE}" "${NODE_SCRIPT}" "${d}" "${NPM_AUDIT_LEVEL}" "${ESLINT_PIN}" "${ESLINT_CONFIG_NEXT_PIN}"
done

# --- Summary ---------------------------------------------------------------
echo
log "================ Quality gate summary: ${NAME} ================"
if [[ -s "${RESULTS_FILE}" ]]; then
  while IFS='|' read -r _ check status; do
    if [[ "${status}" == "PASS" ]]; then
      printf '   \033[0;32m✔ PASS\033[0m  %s\n' "${check}"
    else
      printf '   \033[0;31m✗ FAIL\033[0m  %s\n' "${check}"
    fi
  done <"${RESULTS_FILE}"
else
  warn "No per-check results were captured (a container failed before reporting)."
  GATE_FAIL=1
fi
echo

if [[ "${GATE_FAIL}" -ne 0 ]]; then
  err "Quality gate FAILED for '${NAME}'. Fix the items above before deploying."
  exit 1
fi
log "Quality gate PASSED for '${NAME}'. ✅"
exit 0
