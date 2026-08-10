# shellcheck shell=bash
# ===========================================================================
# pi-system — staged bring-up LIBRARY (pure logic + mockable seams)
# ---------------------------------------------------------------------------
# SOURCED by scripts/startup.sh, scripts/shutdown.sh and the test harness in
# tests/startup/. It mirrors scripts/lib/preflight-lib.sh and
# scripts/lib/mem-budget-lib.sh exactly in spirit:
#
#   1. PURE functions — the ordering, the verify/retry/timeout decision logic,
#      the fold of many container verdicts into one stage verdict, and the
#      profile->stage expansion. They take their inputs as arguments, so the
#      tests verify every decision WITHOUT Docker or a real Pi.
#
#   2. SEAM functions — thin wrappers around the only external calls (docker,
#      docker compose, sleep, the preflight/mem-budget scripts, project
#      discovery). The orchestrators call ONLY these for system access; a test
#      can redefine any of them to inject a fixed value.
#
#   3. The STAGE registry — data mapping each ordered stage to the compose
#      file(s) that define it, the member services it owns, and how each member
#      is verified. It reuses the SAME compose files and Compose profiles the
#      per-service helper scripts use (start-management.sh, db.sh, auth.sh, ...),
#      so this layer ORCHESTRATES the existing platform rather than re-defining
#      it.
#
# DESIGN RULES (kept identical to the sibling libs so the three feel the same):
#   * NO `set -e` here — this is a library; the entrypoint owns shell options.
#   * Classifier functions print their verdict to stdout and `return 0`, so a
#     caller's `set -e` is never tripped by a verdict that happens to be FAIL.
#   * READ-ONLY logic + seams; the only STATE-CHANGING seams (compose up, network
#     create, targeted rm) are clearly named and used solely by the orchestrators
#     — never by the verify/plan logic. NOTHING here deletes a data volume.
#   * The per-stage compose files / profiles are the SINGLE SOURCE OF TRUTH —
#     they are read from the same paths the helpers use, never duplicated.
# ===========================================================================

# Guard against double-sourcing (an entrypoint and the tests may both source it).
if [[ -n "${SU_LIB_SOURCED:-}" ]]; then return 0 2>/dev/null || true; fi
SU_LIB_SOURCED=1

# Reuse the (already tested) profile flattener from the memory-budget library so
# profile expansion is not re-implemented here. mb_flatten expands a boot profile
# into its concrete members (services + label=MiB literals), recursively and
# de-duplicated, with a cycle guard. Sourced relative to THIS file's directory.
SU_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${SU_LIB_DIR}/mem-budget-lib.sh" ]]; then
  # shellcheck source=scripts/lib/mem-budget-lib.sh
  source "${SU_LIB_DIR}/mem-budget-lib.sh"
fi

# ---------------------------------------------------------------------------
# Verdict vocabulary. A per-container probe is one of these; a STAGE is the
# fold of its containers' probes (the worst wins, like preflight's pf_worst).
#   READY  the container/stage is up and confirmed good — proceed.
#   WAIT   not good YET, but not failed either — keep polling until the timeout.
#   FAIL   confirmed bad (unhealthy, exited, crash-looping) — halt the bring-up.
# ---------------------------------------------------------------------------
readonly SU_READY="READY"
readonly SU_WAIT="WAIT"
readonly SU_FAIL="FAIL"

# ===========================================================================
# SECTION 1 — PURE classifiers / planners (the heart of the test surface)
# ===========================================================================

# --- Fold two stage/container verdicts, returning the WORSE of the two ------
# FAIL beats WAIT beats READY. Used to collapse a stage's many container probes
# into one verdict (any FAIL fails the stage; any WAIT keeps it waiting).
su_worst() {
  case "$1|$2" in
    *FAIL*) echo "${SU_FAIL}" ;;
    *WAIT*) echo "${SU_WAIT}" ;;
    *)      echo "${SU_READY}" ;;
  esac
}

# --- Fold a stream of verdicts on stdin into one stage verdict --------------
# Empty input (a stage with no containers to check, e.g. the networks stage once
# its networks exist) folds to READY — nothing is wrong.
su_fold_verdicts() {
  local acc="${SU_READY}" v
  while IFS= read -r v; do
    [[ -n "${v}" ]] || continue
    acc="$(su_worst "${acc}" "${v}")"
  done
  echo "${acc}"
}

# --- The per-container readiness verdict (the core decision) ----------------
# Decides READY / WAIT / FAIL for ONE container from the values a single
# `docker inspect` yields. This is what makes the bring-up "verified": it knows
# the difference between "still starting" (WAIT) and "actually broken" (FAIL),
# and it works for THREE kinds of container:
#
#   * has a Docker HEALTHCHECK  -> trust Docker's health: healthy=READY,
#     unhealthy=FAIL, starting=WAIT. (postgres, mysql, mongo, redis, keycloak-db,
#     n8n-db all declare one.)
#   * NO healthcheck / distroless (no shell to probe) -> fall back to the
#     container STATE: running (and not restarting) = READY; created/restarting =
#     WAIT; exited/dead/paused = FAIL. (caddy, portainer, uptime-kuma, watchtower,
#     homepage, keycloak, n8n, verdaccio, nuget-cache and generated projects have
#     no compose healthcheck — this state probe needs no shell inside the image.)
#   * CRASH-LOOPING -> a universal guard that applies to BOTH kinds: if the
#     restart count has climbed by >= the threshold since we started watching,
#     the container "starts then dies" repeatedly -> FAIL, regardless of the
#     momentary state/health we happened to sample.
#
# Args: <health> <state> <restarting> <restart_count> <baseline_restart_count> <crashloop_threshold>
#   health  = healthy|unhealthy|starting|none   ("none" => no healthcheck)
#   state   = running|created|restarting|paused|exited|dead|removing|""(absent)
#   restarting = true|false
#   restart_count / baseline = integers (current vs. the count first observed)
#   crashloop_threshold = restart delta that means "crash loop" (>0 to enable)
su_probe_verdict() {
  local health="$1" state="$2" restarting="$3"
  local count="${4:-}" baseline="${5:-}" threshold="${6:-0}"

  # Is the container crash-looping? (restart count grew by >= the threshold since
  # we started watching). Computed once, applied below where it matters.
  local crashloop=0
  if [[ "${count}" =~ ^[0-9]+$ && "${baseline}" =~ ^[0-9]+$ && "${threshold}" =~ ^[0-9]+$ ]] \
     && (( threshold > 0 )) && (( count - baseline >= threshold )); then
    crashloop=1
  fi

  if [[ "${health}" != "none" && -n "${health}" ]]; then
    # Container HAS a healthcheck — Docker's verdict is authoritative. A
    # currently-HEALTHY container is READY no matter its restart history; the
    # crash-loop guard only escalates a container that has NOT yet passed its
    # check (still "starting") but keeps dying.
    case "${health}" in
      healthy)   echo "${SU_READY}" ;;
      unhealthy) echo "${SU_FAIL}" ;;
      starting)  (( crashloop )) && echo "${SU_FAIL}" || echo "${SU_WAIT}" ;;
      *)         (( crashloop )) && echo "${SU_FAIL}" || echo "${SU_WAIT}" ;;
    esac
    return 0
  fi

  # No healthcheck — a crash loop is the clearest signal it is broken.
  if (( crashloop )); then echo "${SU_FAIL}"; return 0; fi
  # Otherwise fall back to the container's lifecycle STATE.
  case "${state}" in
    running)
      if [[ "${restarting}" == "true" ]]; then echo "${SU_WAIT}"; else echo "${SU_READY}"; fi ;;
    created|restarting|"") echo "${SU_WAIT}" ;;
    paused|exited|dead|removing) echo "${SU_FAIL}" ;;
    *) echo "${SU_WAIT}" ;;
  esac
}

# --- Parse one `docker inspect` line into its fields -----------------------
# The inspect seam (su_inspect) prints a single TAB-separated line:
#   <state>\t<restarting>\t<restart_count>\t<health-or-none>
# This splits it into the positional args su_probe_verdict expects, tolerating
# an empty line (container not created yet -> treated as state="", health="none").
# Echoes "state<TAB>restarting<TAB>count<TAB>health".
su_parse_inspect() {
  local line="$1" state restarting count health
  IFS=$'\t' read -r state restarting count health <<< "${line}"
  [[ -n "${restarting}" ]] || restarting="false"
  [[ -n "${count}" ]] || count="0"
  [[ -n "${health}" ]] || health="none"
  printf '%s\t%s\t%s\t%s' "${state}" "${restarting}" "${count}" "${health}"
}

# --- Retry backoff: the delay before the Nth poll --------------------------
# Exponential backoff, capped: delay = base * 2^(attempt-1), clamped to [1,max].
# attempt is 1-based (the delay AFTER the first probe is base). Pure integer math.
su_backoff_delay() {
  local attempt="$1" base="$2" max="$3" d="$2" i=1
  (( attempt < 1 )) && attempt=1
  while (( i < attempt )); do d=$(( d * 2 )); i=$(( i + 1 )); (( d > max )) && { d="${max}"; break; }; done
  (( d > max )) && d="${max}"
  (( d < 1 )) && d=1
  echo "${d}"
}

# --- Has the per-stage timeout been reached? -------------------------------
su_deadline_reached() {
  local elapsed="$1" timeout="$2"
  (( elapsed >= timeout )) && echo "yes" || echo "no"
}

# ===========================================================================
# SECTION 2 — The STAGE registry (data, not logic)
# ===========================================================================
# Ordered, DEPENDENCY-CORRECT list of stages. Each later stage may rely on an
# earlier one being healthy:
#   networks    must exist before any container can attach
#   proxy       Caddy — the public edge; create the `proxy` network early
#   management  Portainer / Uptime Kuma / Watchtower — ops + the `internal` net
#   dashboard   Homepage — links to everything above
#   databases   the chosen engine(s) — apps/auth/automation depend on a DB
#   db-admin    pgAdmin / Adminer / Mongo Express — need their DB + the proxy
#   cache       Verdaccio / NuGet mirror — independent dev tooling
#   auth        Keycloak + its OWN db
#   automation  n8n + its OWN db
#   projects    generated apps under services/<name>/ (depend on all of the above)
# The four canonical optional stages from the spec (databases, auth, automation,
# projects) keep their listed relative order; db-admin and cache slot in at the
# only dependency-safe point (after the database that backs them).
SU_STAGE_ORDER=(networks proxy management dashboard databases db-admin cache auth automation projects)

# stage -> human description (for the plan/report).
declare -A SU_STAGE_DESC=(
  [networks]="base shared networks (internal + proxy)"
  [proxy]="reverse proxy (Caddy)"
  [management]="management & monitoring (Portainer, Uptime Kuma, Watchtower)"
  [dashboard]="unified dashboard (Homepage)"
  [databases]="on-demand database engine(s)"
  [db-admin]="database admin UI(s)"
  [cache]="local package cache (Verdaccio + NuGet mirror)"
  [auth]="authentication (Keycloak + its database)"
  [automation]="automation (n8n + its database)"
  [projects]="generated project(s) under services/"
)

# stage -> compose files (space-separated, project-root-relative). Each includes
# the base file so the shared networks resolve, EXACTLY as the helper scripts
# pass them. The networks + projects stages are handled specially (no fixed
# member services), so they only need the base file.
declare -A SU_STAGE_COMPOSE=(
  [networks]="infrastructure/docker-compose.yml"
  [proxy]="infrastructure/docker-compose.yml services/proxy/proxy.compose.yml"
  [management]="infrastructure/docker-compose.yml infrastructure/management.compose.yml"
  [dashboard]="infrastructure/docker-compose.yml services/dashboard/dashboard.compose.yml"
  [databases]="infrastructure/docker-compose.yml services/databases/databases.compose.yml"
  [db-admin]="infrastructure/docker-compose.yml services/db-admin/db-admin.compose.yml"
  [cache]="infrastructure/docker-compose.yml services/cache/cache.compose.yml"
  [auth]="infrastructure/docker-compose.yml services/auth/auth.compose.yml"
  [automation]="infrastructure/docker-compose.yml services/automation/automation.compose.yml"
  [projects]="infrastructure/docker-compose.yml"
)

# stage -> the member SERVICES (compose service names) it owns. These are the
# names passed to `docker compose ps -q <svc>` / `up -d <svc>` and the units the
# verifier probes. For databases / db-admin the operator selects a SUBSET (start
# only the engines/UIs needed); the others bring up their whole set.
declare -A SU_STAGE_SERVICES=(
  [networks]=""
  [proxy]="caddy"
  [management]="portainer uptime-kuma watchtower"
  [dashboard]="homepage"
  [databases]="postgres mysql mongo redis"
  [db-admin]="pgadmin adminer mongo-express"
  [cache]="verdaccio nuget-cache"
  [auth]="keycloak-db keycloak"
  [automation]="n8n-db n8n"
  [projects]=""
)

# service -> the Compose PROFILE that must be enabled to bring it up ("" = none).
# Mirrors the per-service helpers: each database/admin-UI is its own profile, the
# package cache shares the "cache" profile. Everything else needs no profile.
declare -A SU_SERVICE_PROFILE=(
  [postgres]="postgres" [mysql]="mysql" [mongo]="mongo" [redis]="redis"
  [pgadmin]="pgadmin" [adminer]="adminer" [mongo-express]="mongo-express"
  [verdaccio]="cache" [nuget-cache]="cache"
)

# --- service -> stage ------------------------------------------------------
# Maps a boot-profile MEMBER (a service name) to the stage that owns it, so a
# profile like `dev: core postgres verdaccio nuget-cache` expands to the right
# set of stages. Unknown members (e.g. an app-*=MiB planning literal) return ""
# and are handled by the caller (the projects stage is discovered from disk).
su_service_stage() {
  case "$1" in
    caddy)                            echo "proxy" ;;
    portainer|uptime-kuma|watchtower) echo "management" ;;
    homepage)                         echo "dashboard" ;;
    postgres|mysql|mongo|redis)       echo "databases" ;;
    pgadmin|adminer|mongo-express)    echo "db-admin" ;;
    verdaccio|nuget-cache|nuget_cache) echo "cache" ;;
    keycloak|keycloak-db)             echo "auth" ;;
    n8n|n8n-db)                       echo "automation" ;;
    *)                                echo "" ;;
  esac
}

# --- service -> preflight component ----------------------------------------
# preflight.sh scopes its checks by COMPONENT (proxy management postgres ... auth
# automation dashboard cache). This maps a selected service to the component name
# preflight understands, so startup can scope preflight to exactly what it will
# start. Returns "" for an unknown service.
su_preflight_component() {
  case "$1" in
    caddy)                            echo "proxy" ;;
    portainer|uptime-kuma|watchtower) echo "management" ;;
    homepage)                         echo "dashboard" ;;
    postgres)                         echo "postgres" ;;
    mysql)                            echo "mysql" ;;
    mongo)                            echo "mongo" ;;
    redis)                            echo "redis" ;;
    pgadmin)                          echo "pgadmin" ;;
    adminer)                          echo "adminer" ;;
    mongo-express)                    echo "mongo-express" ;;
    verdaccio|nuget-cache|nuget_cache) echo "cache" ;;
    keycloak|keycloak-db)             echo "auth" ;;
    n8n|n8n-db)                       echo "automation" ;;
    *)                                echo "" ;;
  esac
}

# Is NAME a known stage?
su_is_stage() {
  local n="$1" s
  for s in "${SU_STAGE_ORDER[@]}"; do [[ "${s}" == "${n}" ]] && return 0; done
  return 1
}

# The default (full) member set for a stage — used when the operator selects a
# stage by name (e.g. --stages databases) rather than via a profile.
su_stage_default_services() { echo "${SU_STAGE_SERVICES[$1]:-}"; }

# ===========================================================================
# SECTION 3 — Planning (pure): tokens/services -> ordered stage plan
# ===========================================================================

# --- Deduplicate stdin lines, preserving first-seen order ------------------
su_dedup_keep_order() { awk '!seen[$0]++'; }

# --- Build a PLAN from a flat list of services -----------------------------
# Groups the given services by stage and emits, in SU_STAGE_ORDER, one line per
# non-empty stage:  "<stage><TAB><svc> <svc> ...". Members are de-duplicated and
# kept in registry order per stage. label=MiB literals and unknown tokens are
# IGNORED here (literals are planning-only allowances; the projects stage is
# discovered from disk by the orchestrator). PURE — the test surface for
# "profile -> stages" correctness.
su_plan_from_services() {
  local svc st
  declare -A picked=()      # stage -> space-list of selected services
  for svc in "$@"; do
    [[ -n "${svc}" ]] || continue
    [[ "${svc}" == *=* ]] && continue          # planning literal -> skip
    st="$(su_service_stage "${svc}")"
    [[ -n "${st}" ]] || continue               # unknown member -> skip
    case " ${picked[${st}]:-} " in
      *" ${svc} "*) : ;;                        # already picked
      *) picked[${st}]="${picked[${st}]:-}${picked[${st}]:+ }${svc}" ;;
    esac
  done
  for st in "${SU_STAGE_ORDER[@]}"; do
    [[ -n "${picked[${st}]:-}" ]] && printf '%s\t%s\n' "${st}" "${picked[${st}]}"
  done
}

# --- Drive a plan, HALTING after the first failed stage --------------------
# The shared heart of the bring-up loop: walk the given stages in order, calling
# the ORACLE function for each (the oracle does the real work and returns 0 for a
# healthy stage, non-zero for a failed one). Records every stage it actually ran
# in the SU_EXECUTED array and STOPS the moment a stage fails — so later stages
# are never started once one breaks. Returns 0 if all stages passed, 1 otherwise.
#
# scripts/startup.sh drives the live bring-up through this exact function (its
# oracle starts + verifies a stage); the test harness drives it with a MOCKED
# oracle, so the "a failed stage halts the rest" invariant is verified without
# Docker. PURE given a pure oracle.
declare -a SU_EXECUTED=()
su_run_plan() {
  local oracle="$1"; shift
  local st rc=0
  SU_EXECUTED=()
  for st in "$@"; do
    SU_EXECUTED+=("${st}")
    if ! "${oracle}" "${st}"; then rc=1; break; fi
  done
  return "${rc}"
}

# --- Order an arbitrary set of stage names by SU_STAGE_ORDER ----------------
# Reads stage names on stdin, echoes the ones that are valid in canonical order,
# de-duplicated. Used to merge stages chosen via --stages with stages implied by
# a profile, then walk them in dependency order.
su_order_stages() {
  local -A want=() s
  while IFS= read -r s; do [[ -n "${s}" ]] && want[${s}]=1; done
  for s in "${SU_STAGE_ORDER[@]}"; do [[ -n "${want[${s}]:-}" ]] && echo "${s}"; done
}

# --- Expand profile/service tokens into a flat service list ----------------
# Thin wrapper over mb_flatten (from mem-budget-lib): expands any profile token
# (recursively, de-duplicated, cycle-guarded) and passes service / label tokens
# through. "core" is just another profile in boot-profiles.conf, so it expands
# naturally. Needs the boot-profiles.conf path; PURE given that file.
su_expand_tokens() {
  local conf="$1"; shift
  if declare -F mb_flatten >/dev/null 2>&1; then
    mb_flatten "${conf}" "$@"
  else
    printf '%s\n' "$@"
  fi
}

# --- Compose PROFILE flags needed for a stage's selected services ----------
# Echoes each required Compose profile (deduped) for the given services, so the
# orchestrator can add `--profile X` flags. Most services need none.
su_profiles_for_services() {
  local svc p
  for svc in "$@"; do
    p="${SU_SERVICE_PROFILE[${svc}]:-}"
    [[ -n "${p}" ]] && echo "${p}"
  done | su_dedup_keep_order
}

# ===========================================================================
# SECTION 4 — SEAMS (every external/system call lives behind one of these so
#             tests can redefine it; the orchestrators never call the real
#             tools directly). Defaults are the real implementations.
# ===========================================================================

# Is a command available on PATH?
su_have_cmd() { command -v "$1" >/dev/null 2>&1; }

# The docker CLI / Compose v2 (wrapped so tests can stub the whole thing).
su_docker() { command docker "$@"; }
su_docker_running() { su_docker info >/dev/null 2>&1; }
su_compose_available() { su_docker compose version >/dev/null 2>&1; }

# Resolve a stage's service to its container ID for the given compose argv.
# Echoes the ID (empty if the container does not exist yet). READ-ONLY.
# Args: <service> <compose-argv...>
su_service_container_id() {
  local svc="$1"; shift
  su_docker compose "$@" ps -q "${svc}" 2>/dev/null | head -n1 || true
}

# Inspect one container by ID/name. Echoes a single TAB-separated line:
#   <state>\t<restarting>\t<restart_count>\t<health-or-none>
# Empty output if the container is unknown. READ-ONLY (the verify backbone).
su_inspect() {
  local ref="$1"
  [[ -n "${ref}" ]] || { printf ''; return 0; }
  su_docker inspect \
    --format '{{.State.Status}}{{"\t"}}{{.State.Restarting}}{{"\t"}}{{.RestartCount}}{{"\t"}}{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' \
    "${ref}" 2>/dev/null || true
}

# Last N log lines of a container (for the diagnostic tail on FAIL). READ-ONLY.
su_logs_tail() {
  local ref="$1" n="${2:-40}"
  [[ -n "${ref}" ]] || return 0
  su_docker logs --tail "${n}" "${ref}" 2>&1 || true
}

# Does a docker network exist?  (READ-ONLY)
su_network_exists() { su_docker network inspect "$1" >/dev/null 2>&1; }

# Create a docker network (idempotent; if it already exists, that is success;
# optional subnet $3). RETAINED as a generic helper, but NO LONGER used by the
# networks stage: the platform networks are Compose-managed (see run_networks in
# scripts/startup.sh), so Compose — not this function — creates pi_internal /
# pi_proxy with the correct IPAM + com.docker.compose.* labels. Creating them
# here by hand would leave un-labelled twins that Compose refuses to adopt.
su_network_create() {
  local name="$1" driver="${2:-bridge}" subnet="${3:-}"
  su_network_exists "${name}" && return 0
  if [[ -n "${subnet}" ]]; then
    su_docker network create --driver "${driver}" --subnet "${subnet}" "${name}" >/dev/null 2>&1
  else
    su_docker network create --driver "${driver}" "${name}" >/dev/null 2>&1
  fi
  # Treat "lost the race / already exists" as success.
  su_network_exists "${name}"
}

# Discover GENERATED projects under services/<name>/. A project created by
# scripts/new-project.sh has a <name>.compose.yml fragment that embeds the
# machine-readable marker `# pi-system-subdomain:` (the same marker project.sh
# reads). The platform's OWN service dirs (proxy, auth, databases, ...) follow
# the identical services/<name>/<name>.compose.yml shape but do NOT carry that
# marker — so requiring it is exactly what tells a generated project apart from a
# platform service and stops this stage from re-deploying the platform itself.
# Honors SU_SERVICES_DIR for tests. READ-ONLY.
su_discover_projects() {
  local dir="${SU_SERVICES_DIR:-${SU_PROJECT_ROOT:-.}/services}" d name frag
  [[ -d "${dir}" ]] || return 0
  for d in "${dir}"/*/; do
    [[ -d "${d}" ]] || continue
    name="$(basename "${d}")"
    frag="${d}/${name}.compose.yml"
    [[ -f "${frag}" ]] || continue
    grep -q '^# pi-system-subdomain:' "${frag}" 2>/dev/null && echo "${name}"
  done
}

# Sleep (wrapped so tests never actually wait).
su_sleep() { sleep "$1"; }

# Run the read-only preflight / mem-budget checks (seams so tests can stub).
# Echo nothing; return the script's exit code (non-zero => the operator should
# stop). The orchestrator decides whether to honor or --skip them.
su_run_preflight()  { bash "${SU_PROJECT_ROOT:-.}/scripts/preflight.sh"  "$@"; }
su_run_mem_budget() { bash "${SU_PROJECT_ROOT:-.}/scripts/mem-budget.sh" "$@"; }
