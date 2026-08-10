# pi-system

Self-hosted freelance platform running on a **Raspberry Pi 5** (ARM64, SSD over
PCIe) with **Docker + Docker Compose v2**.

> **Foundation + management + edge.** This repository contains the project
> skeleton, the shared Docker networks, a small **management & monitoring
> stack** (Portainer, Uptime Kuma, Watchtower), and a **reverse proxy** (Caddy)
> that fronts them over TLS — all described below. The .NET APIs, Next.js apps,
> databases, etc. are added in later phases under [`services/`](../services).

> ### 🚀 First time on a real Pi? Start with the [**FIRST-RUN RUNBOOK**](RUNBOOK.md).
> [`docs/RUNBOOK.md`](RUNBOOK.md) is the single, ordered, copy-paste guide from a
> bare Pi to a verified, running platform — it **sequences and links** every
> section below (and every deferred one-time step) in the correct, safe order,
> with a verify and an "if it fails" pointer at each stage. This README is the
> **component reference** the runbook points into. Unsure where you are? Run
> `./scripts/pi doctor` for the next command.

---

## Project structure

```
pi-system/
├── infrastructure/        Core compose files (shared networks live here)
│   ├── docker-compose.yml     Defines the `internal` + `proxy` networks only
│   ├── management.compose.yml Management & monitoring stack (Portainer, Uptime Kuma, Watchtower)
│   ├── boot-profiles.conf     Boot-profile → services map (read by mem-budget.sh)
│   └── docker-daemon.json.example  Sample /etc/docker/daemon.json — bounds container log size
├── services/              One subfolder per service (generated projects land here too)
│   ├── proxy/                 Reverse proxy (Caddy): proxy.compose.yml + Caddyfile
│   ├── databases/             On-demand database layer: databases.compose.yml (profiles)
│   ├── db-admin/              On-demand database admin UIs: db-admin.compose.yml (profiles)
│   ├── auth/                  Authentication: auth.compose.yml (Keycloak + its own DB)
│   ├── automation/            Automation: automation.compose.yml (n8n + its own DB)
│   ├── dashboard/             Unified dashboard (Homepage): dashboard.compose.yml + committed config/
│   ├── backup/                Encrypted backups + tested restore (Dockerfile + backup.compose.yml + do-backup.sh)
│   ├── quality/              OPTIONAL quality gate (script-driven; README — runs via scripts/quality.sh)
│   ├── cache/               OPTIONAL local package cache: cache.compose.yml (profile) + verdaccio/ config + optin/ templates
│   ├── analytics/           OPTIONAL web analytics: analytics.compose.yml (profile — Umami + its own DB)
│   ├── control-api/         Web control panel (UI + API): app/ + components/ + control-api.compose.yml + config-registry.json
│   └── <your-project>/        Scaffolded by new-project.sh (Dockerfile + <name>.compose.yml)
├── templates/             Three-layer template system used by the generator
│   ├── base/                  Shared scaffolds every project starts from
│   │   ├── dotnet-api/            Minimal .NET Web API (multi-stage, ARM64)
│   │   ├── nextjs-app/            Minimal Next.js app (standalone, multi-stage, ARM64)
│   │   └── fullstack/             .NET backend + Next.js frontend (backend/ + frontend/)
│   ├── modules/               Composable features (contract, hello-module, i18n-bilingual, content-admin, bookings, auth-sso, whatsapp-integration, local-payments, web-analytics)
│   ├── presets/               Sector recipes (clinic, ecommerce, company-site, real-estate)
│   └── docs/                  Three-layer philosophy + how to extend
├── automation/           n8n workflows to import (exported JSON; internal-operations only)
│   └── workflows/            platform-health-alert.json, telegram-management-bot.json + how-to README
├── data/                  Persistent volumes / bind mounts (git-ignored)
├── secrets/               Passwords, keys, certs (git-ignored)
├── scripts/               Management scripts
│   ├── pi                     ★ UNIFIED CONTROL — one entrypoint (up/down/status/check/health)
│   │                              that ORCHESTRATES the tools below; the primary operator interface
│   ├── status.sh              READ-ONLY whole-system snapshot (up / off / broken) — `pi status`
│   ├── setup.sh               Bootstrap: checks deps, creates dirs, seeds .env
│   ├── preflight.sh           READ-ONLY pre-launch readiness check (run this FIRST)
│   ├── mem-budget.sh          READ-ONLY memory-budget planner (profile vs RAM, run before `up`)
│   ├── startup.sh             Staged, VERIFIED bring-up, one layer at a time — `pi up` orchestrates it
│   ├── shutdown.sh            Reverse-order, DATA-SAFE shutdown — `pi down` orchestrates it
│   ├── lib/                   Shared script libraries
│   │   ├── ctl-lib.sh             Pure control logic (routing / sequencing / status) + seams (sourced)
│   │   ├── preflight-lib.sh       Pure preflight logic + mockable seams (sourced)
│   │   ├── mem-budget-lib.sh      Pure memory-budget logic + mockable seams (sourced)
│   │   ├── startup-lib.sh         Pure staged-bring-up logic + mockable seams (sourced)
│   │   ├── health-monitor-lib.sh  Pure host-health logic + mockable seams (sourced)
│   │   ├── bot-lib.sh             Pure Telegram-bot logic (parser/allowlist/validation) + seams (sourced)
│   │   ├── seo-lib.sh             Pure SEO helper logic (action/engine/site-list parsing) (sourced)
│   │   └── prospects-lib.sh       Pure prospect-organizer logic (actions/status transitions/slug) (sourced)
│   ├── start-management.sh    Brings up only the management & monitoring stack
│   ├── start-proxy.sh         Brings up the reverse proxy + the stack it fronts
│   ├── db.sh                  Start/stop/inspect a single on-demand database
│   ├── db-admin.sh            Start/stop/inspect a single on-demand database admin UI
│   ├── auth.sh                Start/stop/inspect the auth stack (Keycloak + its DB)
│   ├── automation.sh          Start/stop/inspect the automation stack (n8n + its DB)
│   ├── bot-exec.sh            Audited bridge for the Telegram bot — whitelisted actions only, logged
│   ├── dashboard.sh           Start/stop/inspect the unified dashboard (Homepage)
│   ├── harden-firewall.sh     Stage a strict UFW ruleset (operator enables it manually)
│   ├── generate-secrets.sh    Fill .env secrets with strong random values
│   ├── check-secrets.sh       Audit .env secrets (empty/weak), no values revealed
│   ├── new-project.sh         Scaffold a project from a preset (or base + modules)
│   ├── project.sh             Start/stop/inspect a generated project
│   ├── quality.sh             OPTIONAL quality gate: lint + analyze + audit a generated project
│   ├── cache.sh               OPTIONAL local package cache (npm + NuGet): up/down/logs/status
│   ├── analytics.sh           OPTIONAL self-hosted web analytics (Umami): up/down/logs/status
│   ├── seo.sh                 OPTIONAL SEO/site-quality auditor for sites you own: audit/list/trend
│   ├── seo-install-cron.sh    Install the weekly SEO audit schedule (host cron)
│   ├── prospects.sh           OPTIONAL client prospect organizer (manual CRM-lite + public-site analysis)
│   ├── prospects-install-cron.sh  Install the daily prospect follow-up reminder (host cron, to YOU)
│   ├── deploy-to-tunnel.sh    Publish a generated project to the internet via Cloudflare Tunnel
│   ├── backup.sh              Encrypted backup front door (init-key, now, list, verify, status)
│   ├── backup-verify.sh       Tested-restore DRILL into disposable throwaway containers
│   ├── restore.sh             Guarded REAL restore into live databases (operator-confirmed)
│   ├── backup-install-cron.sh Install the daily backup + weekly drill schedule (host cron)
│   ├── health-monitor.sh     READ-ONLY host health probe (CPU temp/disk/memory) — ongoing
│   └── health-monitor-install-cron.sh  Install the periodic host-health schedule (host cron)
├── tests/                 Offline test harnesses (no Docker/Pi needed)
│   ├── preflight/             Unit tests + fixtures for scripts/preflight.sh (run.sh)
│   ├── mem-budget/            Unit tests + fixtures for scripts/mem-budget.sh (run.sh)
│   ├── startup/               Unit tests + fixtures for scripts/startup.sh + shutdown.sh (run.sh)
│   ├── health-monitor/        Unit tests + fixtures for scripts/health-monitor.sh (run.sh)
│   ├── ctl/                   Unit tests + fixtures for scripts/pi + status.sh (run.sh)
│   ├── bot/                   Unit tests + fixtures for the Telegram bot (bot-lib + bot-exec) (run.sh)
│   ├── analytics/             Unit tests + fixtures for the web-analytics module + analytics service (run.sh)
│   ├── seo/                   Unit tests + fixtures for the SEO engine + seo-toolkit module + service (run.sh)
│   └── prospects/             Unit tests + fixtures for the prospect organizer (pipeline/analyze-reuse/no-send) (run.sh)
├── docs/                  Documentation (you are here)
│   ├── README.md              This file
│   └── cloudflare-tunnel.md   Public hosting: Cloudflare Tunnel + Let's Encrypt walkthrough
├── .env.example           Template of every environment variable (no real values)
├── .env                   Your real config — created from the template, git-ignored
├── .gitignore             Excludes .env, /secrets, /data and sensitive files
└── .gitattributes         Forces LF endings so scripts run on Linux
```

### The two networks

| Network    | Driver | Purpose                                                              |
| ---------- | ------ | ------------------------------------------------------------------- |
| `internal` | bridge | Trusted service-to-service traffic (apps ⇄ databases, caches, ...). Not exposed to the outside. |
| `proxy`    | bridge | Public-facing edge — the reverse proxy and anything reachable from outside the Pi attach here. |

Subnets and names are configurable via `.env` (sensible defaults are baked into
the compose file, so it works even with a blank `.env`).

> A Docker network is only *created* once a service references it. With no
> services yet, `up` is effectively a no-op — use `config` (below) to validate.

---

## Prerequisites

- Raspberry Pi 5 running Raspberry Pi OS Lite (64-bit) or Debian (ARM64).
- Docker Engine + the Docker Compose v2 plugin:
  ```bash
  curl -fsSL https://get.docker.com | sh
  sudo apt-get install -y docker-compose-plugin
  sudo usermod -aG docker "$USER"   # log out/in afterwards
  ```

---

## Bring it up

> **For a first run on a fresh Pi, follow the [FIRST-RUN RUNBOOK](RUNBOOK.md)
> instead** — it adds the hardware/OS prep, secrets, firewall, backups and the
> deferred one-time steps around this core loop, in order. The quickstart below
> is the day-to-day loop once the Pi is already set up.

From the **project root**, the whole platform is driven by a single command —
[`scripts/pi`](../scripts/pi), the **unified control** entrypoint:

```bash
# 1. Bootstrap: verify Docker, create data/ + secrets/, seed .env  (one time)
./scripts/setup.sh

# 2. Edit .env and fill in your values
nano .env

# 3. CHECK: read-only readiness — runs preflight + memory budget, starts nothing.
./scripts/pi check --profile core

# 4. GO LIVE: the guided bring-up. `pi up` runs the canonical sequence end to end
#    — preflight → memory budget → staged, verified bring-up — and HALTS on the
#    first failure with one aggregated report. Default profile is core.
./scripts/pi up --profile core

# 5. STATUS: one whole-system snapshot — what's up / off / broken, host health,
#    generated projects, and an overall verdict.
./scripts/pi status

# ... and stop it again safely (containers removed, all data volumes kept):
./scripts/pi down
```

That is the entire day-to-day workflow. `scripts/pi` is a **thin orchestrator**:
it sequences the same read-only and bring-up tools documented below and prints an
aggregated result — it does not replace them, and each is still runnable on its
own when you want to drive one step directly. See **[Unified control](#unified-control-scriptspi)**
next for every subcommand.

> The compose file lives in `infrastructure/` while `.env` lives at the project
> root, so the underlying tools always pass `--env-file .env` and
> `-f infrastructure/docker-compose.yml` for you.

> `pi up` **will not proceed** if the read-only preflight or memory-budget gate
> FAILs (override with `--skip-checks`). It is safe to re-run: healthy stages are
> detected and left untouched.

---

## Unified control (`scripts/pi`)

[`scripts/pi`](../scripts/pi) is the **single operator interface** to the whole
platform. Instead of remembering the order of five separate scripts, you run one
command with a subcommand. It is a **thin dispatcher**: it routes arguments,
**sequences the existing tools**, and prints an aggregated report — the real work
stays in those tools (and their tested libraries), which it *orchestrates* rather
than re-implements.

| Command | What it does | Orchestrates |
| ------- | ------------ | ------------ |
| `pi check [scope]` | Read-only gates only — answer "is the Pi ready?" Starts **nothing**. | [`preflight.sh`](../scripts/preflight.sh) → [`mem-budget.sh`](../scripts/mem-budget.sh) |
| `pi up [scope]` | **Guided go-live.** Runs the canonical sequence **preflight → memory budget → staged, verified bring-up**, HALTING on the first failure, then prints one aggregated summary + verdict. | the two gates, then [`startup.sh`](../scripts/startup.sh) with `--skip-checks` (the gates already ran) |
| `pi status [-q]` | **Whole-system snapshot:** per-service up / off / broken, the base networks, generated projects, a one-line host-health summary, and an overall verdict. | [`status.sh`](../scripts/status.sh) (+ [`health-monitor.sh`](../scripts/health-monitor.sh) quiet) |
| `pi health [opts]` | Run the Pi **hardware** health probe once (temp / disk / memory). | [`health-monitor.sh`](../scripts/health-monitor.sh) |
| `pi down [scope]` | Reverse-order, **DATA-SAFE** shutdown (named volumes are always kept). | [`shutdown.sh`](../scripts/shutdown.sh) |
| `pi doctor` | **First-run bridge** (read-only): reads `.env` + secrets + live status and prints the single **next command** to run, mapped to a step in the [RUNBOOK](RUNBOOK.md). Alias: `pi runbook`. | [`check-secrets.sh`](../scripts/check-secrets.sh) + [`status.sh`](../scripts/status.sh) |
| `pi help [command]` | Usage for everything, or the underlying tool's help for one command. | — |

**Scope** is shared by `up` / `check` / `down` and defaults to the **core**
profile — it never forces the whole stack up:

```bash
./scripts/pi up --profile dev               # core + one DB + the package cache
./scripts/pi up --services "postgres redis" # extra services, unioned with the profile
./scripts/pi up --profile core --dry-run    # just print the staged plan (starts nothing)
./scripts/pi up --skip-checks -y            # skip BOTH read-only gates (you own the risk)
./scripts/pi check --profile auth           # is the host ready for Keycloak? (read-only)
./scripts/pi down --profile auth            # stop only the auth stage (data kept)
./scripts/pi status -q                      # one-line verdict, for a script or cron
```

Anything `pi` doesn't interpret itself is **passed through unchanged** to the
underlying tool (`--stages`, `--with-projects`, `--ram`, `--os-reserve`,
`--timeout`, `-y`, `-q`, …). Because `pi up` runs preflight + mem-budget itself,
it invokes `startup.sh` with `--skip-checks` so the gates are **never run twice**.

**Reading `pi up`.** Each underlying tool prints its own detailed report; `pi`
then prints a compact roll-up — one line per step — and a final verdict:

```
== go-live summary ==
  ✓ preflight   PASS    — host readiness (read-only)
  ✓ mem-budget  PASS    — memory budget (read-only)
  ✓ startup     PASS    — staged, verified bring-up
VERDICT: LIVE — every step passed; the selected stack is up.
```

If a step fails, the run **halts there**, the rest are marked `SKIPPED`, and the
verdict is `HALTED` (exit 1) — nothing after the failure was started:

```
== go-live summary ==
  ✓ preflight   PASS    — host readiness (read-only)
  ✗ mem-budget  FAIL    — memory budget (read-only)
  · startup     SKIPPED (a prior step failed)
VERDICT: HALTED — "mem-budget" failed; nothing after it ran.
```

Exit code: **0** on success, **1** if a step failed / the system is degraded,
**2** on a usage error.

### `pi status` — the whole-system view

`pi status` aggregates the existing sources into one dashboard-like view. It is
**strictly read-only** (read-only `docker` verbs + a read-only health probe;
never prints a secret) and reuses the **same** per-container probe logic the
staged bring-up uses, so "healthy / broken" means exactly the same thing here as
during `pi up`. It distinguishes **off** (a profile-gated service intentionally
not running) from **broken** (a container that exists but exited / is unhealthy),
lists discovered generated projects and their up/down state, folds in the host
hardware health, and ends with one verdict: **UP**, **DOWN** (nothing running,
not an error), or **DEGRADED** (something running is broken → exit 1).

### Tested

The control logic — subcommand routing, the `up`/`check` step order, the
halt-on-first-failure sequencing driver, scope resolution, flag pass-through, and
the `status` label / tally / verdict aggregation — lives in
[`scripts/lib/ctl-lib.sh`](../scripts/lib/ctl-lib.sh) behind mockable seams, and
is unit-tested against fixtures and **mocked seams** (no Docker/Pi). The headline
contract — `up` invokes **preflight → mem-budget → startup in that order and
halts if an earlier step fails** — is proven by overriding the seams and asserting
the call order:

```bash
./tests/ctl/run.sh    # exits non-zero on any failure
```

See [`tests/ctl/README.md`](../tests/ctl/README.md) for the full coverage.

---

## Preflight check

[`scripts/preflight.sh`](../scripts/preflight.sh) is a **read-only readiness
check** you run on the Pi **before bringing anything up**. It diagnoses the most
likely first-run failures early and prints a clear **PASS / WARN / FAIL** report
with a final verdict. It is the **recommended first step of the final manual
session** — run it, fix any FAILs, then start services.

> **Read-only by design.** It never starts or stops a container, writes a
> secret, pulls an image, or touches a volume — only reads, parses and queries
> (read-only `docker` verbs). It never prints secret values.

### What it verifies

| Area | Checks |
| ---- | ------ |
| **Host** | Docker installed + daemon running; Docker Compose v2; CPU is `arm64` (else WARN); enough free disk on the SSD (configurable); total / available RAM. |
| **Boot media** | Whether `/` is on an SSD vs an **SD/eMMC card** (write-wear risk) — best-effort, a WARN if it looks like a card. |
| **Environment** | `.env` exists; every **required** variable for the scoped services is present and non-empty; **secret strength** via [`check-secrets.sh`](../scripts/check-secrets.sh) (the platform-wide empty/weak/Redis/n8n-key/backup-key criticals — reused, not duplicated). |
| **Compose** | Every scoped compose merge **parses** (`docker compose config`); obvious **host-port** and **container-name** collisions. |
| **Images** | Each pinned image tag still **exists** in the registry and advertises **`linux/arm64`**. A network failure here is a **WARN (offline)**, never a false FAIL. |
| **Networks / volumes** | Which named networks / volumes already exist vs will be created on first `up`. |

### Scope it to what you intend to run

Not everything runs at once on a Pi, so the ENV / COMPOSE / IMAGE checks are
**scoped**. By default preflight checks the always-on **core** (`proxy` +
`management`) **plus anything currently running** (auto-detected via `docker ps`).

```bash
./scripts/preflight.sh                       # core + whatever is already up
./scripts/preflight.sh --services postgres,auth   # core's job done elsewhere? scope to these
./scripts/preflight.sh --all                 # check every component the platform can run
./scripts/preflight.sh --quiet               # only FAILs + the final summary
PREFLIGHT_SERVICES="redis automation" ./scripts/preflight.sh
```

Known components: `proxy management postgres mysql mongo redis pgadmin adminer
mongo-express auth automation dashboard cache backup` (and `core` =
`proxy`+`management`). Tunables: `--disk-threshold <GB>` (WARN below, default 10)
and `--ram-threshold <MB>` (WARN below, default 3500).

### Reading the verdict

Each line is `✓ PASS`, `! WARN`, or `✗ FAIL`, grouped by area, then a summary and
one of:

- **`VERDICT: READY`** — all checks passed; proceed.
- **`VERDICT: READY (with N warning(s))`** — nothing blocks bring-up, but review
  the WARNs (e.g. non-arm64 dev box, offline image checks, an SD card).
- **`VERDICT: NOT READY`** — one or more **FAILs**; fix them first.

The exit code is **0** when there are no FAILs (warnings are allowed) and **1**
otherwise, so it doubles as a gate in a script. Offline (no internet) only
produces WARNs for the registry checks — it never fails the run on its own.

### Tested

The decision logic (classifiers, parsers, the component registry) lives in
[`scripts/lib/preflight-lib.sh`](../scripts/lib/preflight-lib.sh) behind mockable
seams, and is unit-tested against fixtures **without a live Docker/Pi**:

```bash
./tests/preflight/run.sh    # exits non-zero on any failure
```

See [`tests/preflight/README.md`](../tests/preflight/README.md) for the full
coverage (missing `.env`, weak secret — including a real `check-secrets.sh` run,
missing required var, bad compose, tag-missing, low-disk / low-RAM, offline).

---

## Resource safety

A Raspberry Pi has a fixed, modest amount of RAM, and the biggest first-run risk
is **running too many services at once** so the kernel starts OOM-killing
containers (or the whole box thrashes). Two things keep that from happening:

1. **Every long-running service declares a memory limit** (`deploy.resources.limits.memory`),
   so no single container can grow without bound and starve the others.
2. **Boot profiles** name sensible groups of services to run together, and
   [`scripts/mem-budget.sh`](../scripts/mem-budget.sh) sums a profile's limits and
   checks them against the Pi's RAM **before** you bring anything up.

Run it as the step **between** preflight and `up`:

```bash
./scripts/preflight.sh            # 1. is the host ready at all?
./scripts/mem-budget.sh auth      # 2. does this profile fit in this Pi's RAM?
./scripts/auth.sh up              # 3. ... then bring it up
```

> **Read-only by design.** `mem-budget.sh` only reads the compose files (for each
> limit), [`infrastructure/boot-profiles.conf`](../infrastructure/boot-profiles.conf)
> (for the profile → members map) and `/proc/meminfo` (for total RAM). It never
> starts/stops a container, pulls an image, writes anything, or prints a secret —
> and it does not even need Docker.

### Memory-limit source of truth

Every service and its cap. This table is mirrored live by
`./scripts/mem-budget.sh --table`, which reads the limits **straight from the
compose files**, so the two can never drift.

| Service | Limit | Why this number |
| ------- | ----: | --------------- |
| `caddy` | 128M | Reverse proxy (Go) — small and mostly idle; the only host-port binder. |
| `portainer` | 256M | Docker management UI (Go) — light. |
| `uptime-kuma` | 256M | Monitoring + status page (Node) — light; grows a little with monitors. |
| `watchtower` | 128M | Notify-only update checker (Go) — idle except a weekly scan. |
| `homepage` | 256M | Unified dashboard (Next.js) — light. |
| `postgres` | 256M | Recommended relational engine — comfortable for the small app DBs here. |
| `mysql` | 512M | Alternative relational engine — InnoDB buffers make it the heaviest DB. |
| `mongo` | 512M | Document DB — the WiredTiger cache wants room. |
| `redis` | 256M | In-memory store — the cap also bounds the dataset. |
| `pgadmin` | 256M | Full pgAdmin (Python/Flask) — the heaviest admin UI. |
| `adminer` | 128M | Single-file PHP UI — tiny. |
| `mongo-express` | 256M | Mongo web UI (Node). |
| `keycloak` | 768M | JVM/Quarkus IdP — the **heaviest** service; heap capped at `-Xmx512m`, +256M for metaspace, off-heap and first-boot augmentation. |
| `keycloak-db` | 256M | Keycloak's own isolated PostgreSQL. |
| `n8n` | 512M | Automation engine (Node) — baseline for light internal workflows. |
| `n8n-db` | 256M | n8n's own isolated PostgreSQL. |
| `verdaccio` | 256M | Local npm registry/cache (Node). |
| `nuget-cache` | 384M | BaGetter NuGet mirror (ASP.NET Core) — JIT + first-run. |
| `backup` | 256M | One-shot dump/encrypt job (profile `backup`); **not** always-on — it runs transiently alongside whatever else is up. |

**Generated projects** add to this on top of the platform: a `dotnet-api` or
`nextjs-app` service is **256M**; a `fullstack` project is **512M** (web 256 +
api 256); the `content-admin` module adds **768M** (Directus 512 + its own DB
256). The merge-only modules (`auth-sso`, `whatsapp-integration`,
`local-payments`) add **no** container. The optional **quality gate**
(`scripts/quality.sh`) is not in this table because it runs throwaway SDK
containers **one at a time** on demand and nothing stays resident.

### Boot profiles

Profiles are **documented presets**, not new always-on services and not an
orchestrator — they live as a small line-based map in
[`infrastructure/boot-profiles.conf`](../infrastructure/boot-profiles.conf) (a
member is a service, another profile, or a `label=MiB` allowance) and are read by
`mem-budget.sh`. Bring a profile up with the existing per-service helper scripts.

| Profile | What runs | Footprint | Bring up with |
| ------- | --------- | --------: | ------------- |
| **core** | Caddy + Portainer + Uptime Kuma + Watchtower + Homepage — the minimal **always-on** set | ~1.0 GiB | `start-proxy.sh` + `start-management.sh` + `dashboard.sh up` |
| **dev** | core + PostgreSQL + the package cache (npm + NuGet) | ~1.9 GiB | core, then `db.sh postgres up` + `cache.sh up` |
| **auth** | core + Keycloak + its DB (only when you need SSO) | ~2.0 GiB | core, then `auth.sh up` |
| **automation** | core + n8n + its DB (only when you need n8n) | ~1.8 GiB | core, then `automation.sh up` |
| **full-ish** | **WARNING / illustrative** — core + every DB + every admin UI + auth + automation + cache + two sample projects | ~7.3 GiB | *do not run as-is* |

`full-ish` is deliberately a "what **not** to run all at once" reference: it is
expected to **FAIL** the budget on an 8 GB Pi and **PASS** on 16 GB.

```bash
./scripts/mem-budget.sh                 # list every profile + its footprint + verdict
./scripts/mem-budget.sh auth            # budget one profile against this Pi's RAM
./scripts/mem-budget.sh core postgres myshop=512   # core + a DB + a planned project
./scripts/mem-budget.sh --table         # the memory-limit source of truth (above)
./scripts/mem-budget.sh --ram 8192 full-ish        # plan for an 8 GB Pi without one
```

The verdict reserves **1 GiB** for the OS, Docker and the page cache by default
(`--os-reserve`), then compares the requested total against the rest:
**PASS** comfortably under, **WARN** above 85% of the safe budget (little room
left for builds or a project), **FAIL** over budget — or if any selected service
has no memory limit at all. Exit code is **0** on PASS/WARN and **1** on FAIL, so
it doubles as a gate.

### 8 GB vs 16 GB

Default OS reserve is 1 GiB, so the **safe budget** is roughly total RAM minus a
little firmware overhead minus that 1 GiB.

| Scenario | 8 GB Pi (≈6.8 GiB safe) | 16 GB Pi (≈15 GiB safe) |
| --- | --- | --- |
| Always-on `core` (~1.0 GiB) | ✅ plenty spare | ✅ trivial |
| `core` + **one** heavy stack (`auth` *or* `automation` *or* `dev`) + a project or two | ✅ comfortable | ✅ |
| `core` + `auth` + `automation` together (~2.8 GiB) | ✅ fits (~4 GiB spare) | ✅ roomy |
| `core` + `auth` + `automation` + a DB + several projects | ✅ fits — budget it and watch the WARN band | ✅ roomy |
| **Everything at once** — all DBs + all admin UIs + auth + automation + cache + projects (`full-ish`, ~7.3 GiB) | ❌ exceeds RAM | ✅ fits |

So on either Pi the **sum of caps** for most sensible combinations fits — what
actually overflows 8 GB is running *everything* (every database + every admin UI
+ auth + automation + cache) **while also** hosting projects, i.e. `full-ish`.

> **Caps are not reservations.** A limit is the most a container *may* use, not
> what it reserves. The 1 GiB OS reserve and the 85% WARN band exist precisely so
> there is real RAM left for the kernel page cache, `docker build` / `npm install`
> / `dotnet restore`, and a container's actual working set — don't plan to use the
> safe budget to the last megabyte.

**On 8 GB:** keep `core` running and bring heavy stacks (`auth`, `automation`,
the heavier databases like MySQL/MongoDB) up **only when needed**, down when idle
— they are all on-demand by design. Budget the exact set first, e.g.
`./scripts/mem-budget.sh core auth postgres myshop=512`. **On 16 GB:** you can
keep `core`, `auth` and `automation` resident together and still host several
projects; even `full-ish` passes with room to spare.

### Tested

The summation and verdict logic lives in
[`scripts/lib/mem-budget-lib.sh`](../scripts/lib/mem-budget-lib.sh) behind mockable
seams and is unit-tested against fixtures **without Docker or a Pi**:

```bash
./tests/mem-budget/run.sh    # exits non-zero on any failure
```

It covers value conversion, per-service limit parsing (incl. the MAX over a
limit + reservation), **missing-limit detection**, profile expansion + a cycle
guard, the OS-headroom math, the verdict bands, a profile that **fits** and one
that **exceeds** RAM, and two real-repo invariants: every platform service
declares a limit, and every member of every real profile resolves (no typos).
See [`tests/mem-budget/README.md`](../tests/mem-budget/README.md).

---

## Staged bring-up

[`scripts/startup.sh`](../scripts/startup.sh) is the **engine** behind
`scripts/pi up` — the staged bring-up the unified control command drives (run it
directly when you want to bring the platform up one step yourself). Instead of
starting everything at once — the surest way to drown in a tangle of failures on a
brand-new Pi — it brings the platform up **one dependency-ordered layer at a
time** and **verifies each layer is genuinely healthy before allowing the next**.
A failure is then **isolated to the stage that caused it**, with that container's
last log lines printed so you can fix exactly one thing and re-run.

It orchestrates the existing per-service compose files and Compose profiles (the
same ones [`scripts/start-management.sh`](../scripts/start-management.sh),
[`scripts/db.sh`](../scripts/db.sh), [`scripts/auth.sh`](../scripts/auth.sh), …
use) — it does **not** replace them.

### The recommended flow

The one-command path is **[`scripts/pi up`](#unified-control-scriptspi)**, which
runs the read-only gates and this staged bring-up in sequence:

```bash
./scripts/pi up --profile core         # preflight → mem-budget → staged bring-up
```

Driving the underlying tools by hand does the same thing, in three explicit steps:

```bash
./scripts/preflight.sh                 # 1. is the host ready at all? (read-only)
./scripts/mem-budget.sh core           # 2. does this profile fit in RAM? (read-only)
./scripts/startup.sh --profile core    # 3. staged, verified bring-up
```

Step 3 actually **re-runs steps 1 and 2 for you**, scoped to exactly what it is
about to start, and **refuses to proceed if either FAILs** (override with
`--skip-checks`). When you go through `scripts/pi up`, the dispatcher runs the
gates itself and then calls `startup.sh --skip-checks`, so they run **once**, not
twice — the aggregated report still shows all three steps.

### Stage order — and why

Each stage is confirmed healthy before the next begins:

| # | Stage | What | Why here |
|---|-------|------|----------|
| 1 | `networks`   | the shared `internal` + `proxy` networks | everything attaches to them |
| 2 | `proxy`      | Caddy | the public edge; brings up the `proxy` network |
| 3 | `management` | Portainer, Uptime Kuma, Watchtower | ops/monitoring + the `internal` network |
| 4 | `dashboard`  | Homepage | links to everything above |
| 5 | `databases`  | the chosen engine(s) | apps / auth / automation depend on a DB |
| 6 | `db-admin`   | pgAdmin / Adminer / Mongo Express | need their DB **and** the proxy |
| 7 | `cache`      | Verdaccio + NuGet mirror | independent dev tooling |
| 8 | `auth`       | Keycloak **+ its own DB** | the heaviest service — opt in |
| 9 | `automation` | n8n **+ its own DB** | opt in when you need it |
| 10 | `projects`  | generated apps under `services/<name>/` | depend on all of the above |

Stages 1–4 are the always-on **core**; 5–10 run **only if your profile or flags
select them**. `startup.sh` **never forces the whole stack up**.

### Selecting what comes up

Scope is the operator's choice — by boot profile, by service, or by stage:

```bash
./scripts/startup.sh --profile core             # default: the always-on core
./scripts/startup.sh --profile dev              # core + Postgres + the package cache
./scripts/startup.sh --profile auth             # core + Keycloak + its DB
./scripts/startup.sh --profile core --services "postgres redis"   # union
./scripts/startup.sh --stages "databases,auth"  # just those stages (networks always first)
./scripts/startup.sh --with-projects            # also deploy generated projects
./scripts/startup.sh --profile dev --dry-run    # print the plan; start nothing
```

Profiles come from [`infrastructure/boot-profiles.conf`](../infrastructure/boot-profiles.conf)
(the same single source of truth `mem-budget.sh` reads) and **nest** — every one
builds on `core`. For `databases` / `db-admin` you get **only the engine(s)/UI(s)
your profile selected**, not all of them. Generated projects are **opt-in**
(`--with-projects` / `--stages projects`) so a bring-up never deploys an app
behind your back. `--dry-run` prints the full ordered plan (stages, services, and
how each is verified) and exits without touching Docker.

### How verification works

After a stage's containers are started, each member is polled until it is proven
ready, fails, or the per-stage timeout elapses. The probe adapts to the service:

- **Has a Docker healthcheck** (every database, plus `keycloak-db` / `n8n-db`):
  Docker's own health is authoritative — `healthy` ⇒ ready, `unhealthy` ⇒ fail,
  `starting` ⇒ keep waiting.
- **No healthcheck / distroless image** (Caddy, Portainer, Uptime Kuma,
  Watchtower, Homepage, Keycloak, n8n, the cache, generated projects): there is
  often no shell inside the image to probe, so the fallback reads the **container
  lifecycle state** via `docker inspect` — `running` (and not restarting) ⇒
  ready; `created`/`restarting` ⇒ wait; `exited`/`dead`/`paused` ⇒ fail. This
  needs nothing inside the container.
- **Crash-loop guard** (both kinds): if a container's restart count climbs by
  `--crashloop-restarts` (default 3) while we watch, it is "starting then dying"
  repeatedly ⇒ fail — even if a single sample caught it momentarily `running`.

Polling uses a few **retries with exponential backoff** (`--interval`, capped at
`--max-interval`) up to a per-stage `--timeout` (default 120 s). All are
configurable:

```bash
./scripts/startup.sh --profile auth --timeout 240 --interval 5 --max-interval 20
```

> Keycloak and n8n re-augment / run migrations on first boot and are slow on a
> Pi — raise `--timeout` for the `auth` / `automation` profiles on first run.

### How a failure is isolated and diagnosed

The moment a stage fails verification, `startup.sh` **stops** — later stages are
never started — prints a `✗ FAIL` for that stage, and dumps the **last ~40 log
lines of the offending container(s)** so the cause is right there. The final
summary shows each stage's `PASS` / `FAIL` and marks the stages that were
`SKIPPED` because an earlier one halted the run. Fix the one stage, then re-run.

### Idempotent — safe to re-run

Re-running `startup.sh` **detects what is already healthy and leaves it
untouched** (it pre-probes each stage and skips the bring-up if every member is
already ready). So after a fix you can simply run it again, and bringing up a
**superset** profile only starts the **missing** stages.

### Stopping safely

[`scripts/shutdown.sh`](../scripts/shutdown.sh) is the mirror image: it stops the
platform in the **reverse** order (`projects → automation → auth → cache →
db-admin → databases → dashboard → management → proxy`). It is **data-safe by
design** — like every helper it uses a targeted `docker compose rm -sf` and
**never** `docker compose down` (which would tear down the shared networks/other
stacks) and **never** `down -v` or removes a named volume. All database /
identity / workflow / cache / certificate data **survives**.

```bash
./scripts/shutdown.sh                       # stop everything (data kept)
./scripts/shutdown.sh --profile auth        # stop just the auth profile's stages
./scripts/shutdown.sh --stages automation   # stop only the automation stage
./scripts/shutdown.sh --remove-networks     # also remove the shared networks (if idle)
```

The shared networks are left in place by default (cheap, shared, harmless);
`--remove-networks` removes them only once nothing is still attached.

### Tested

The ordering, the verify/timeout/retry decision logic, the profile→stage
expansion, and the **"a failed stage halts the rest"** invariant all live in
[`scripts/lib/startup-lib.sh`](../scripts/lib/startup-lib.sh) behind mockable
seams, and are unit-tested **without Docker or a Pi**:

```bash
./tests/startup/run.sh    # exits non-zero on any failure
```

It covers stage ordering + dependency correctness, the per-container probe across
healthy / unhealthy / starting / no-healthcheck / crash-loop, folding many
containers into one stage verdict, backoff + timeout, profile→stage expansion
(incl. a reference cycle), generated-project discovery (a marked project vs. a
platform service dir), the halt-on-failure driver, and real-repo invariants
(every stage's compose files exist; every boot-profile member maps to a stage).
See [`tests/startup/README.md`](../tests/startup/README.md).

---

## Management & monitoring

The operations layer lives in
[`infrastructure/management.compose.yml`](../infrastructure/management.compose.yml)
and adds three small, ARM64, version-pinned services on top of the base
networks.

| Service          | Image                              | Network(s)          | What it does                                                                 |
| ---------------- | ---------------------------------- | ------------------- | --------------------------------------------------------------------------- |
| **Portainer CE** | `portainer/portainer-ce:2.21.4-alpine` | `proxy`         | Visual UI to manage the local Docker engine (containers, images, volumes, logs). |
| **Uptime Kuma**  | `louislam/uptime-kuma:1.23.16`     | `internal` + `proxy`| Uptime monitoring + status page. On `internal` it can probe other services directly; on `proxy` its dashboard can be published. |
| **Watchtower**   | `containrrr/watchtower:1.7.1`      | `internal`          | **Notify-only** update checker — see below.                                  |

### Start it

```bash
# Brings up ONLY the management stack (passes the base + management compose
# files together so the shared networks are inherited).
./scripts/start-management.sh
```

Equivalent manual command from the project root:

```bash
docker compose --env-file .env \
  -f infrastructure/docker-compose.yml \
  -f infrastructure/management.compose.yml \
  up -d
```

### How to access

Both UIs attach to the `proxy` network and publish **no host ports** — the
reverse proxy (next section) routes to them (Portainer on container port
`9000`, Uptime Kuma on `3001`) and terminates TLS:

| UI          | URL                                |
| ----------- | ---------------------------------- |
| Portainer   | `https://portainer.<BASE_DOMAIN>`  |
| Uptime Kuma | `https://status.<BASE_DOMAIN>`     |

`BASE_DOMAIN` defaults to `localhost`, so out of the box they answer at
`https://portainer.localhost` and `https://status.localhost`.

If the proxy is ever down, you can fall back to **emergency** direct access by
uncommenting a `Bootstrap access` block in `management.compose.yml` (and
optionally setting `PORTAINER_HTTP_PORT` / `UPTIME_KUMA_PORT` in `.env`), then
visiting `http://<pi-ip>:9000` / `http://<pi-ip>:3001`. Re-comment it after.

> On first launch, open Portainer promptly to create the admin account — it
> locks new-account creation a few minutes after startup as a safety measure.

### Why Watchtower is intentionally notify-only

Watchtower can auto-pull and recreate containers when new images appear. On a
single self-hosted box that hosts real services, a silent overnight upgrade can
introduce a breaking change with no one watching. So it is configured to
**check and report only**:

- `WATCHTOWER_MONITOR_ONLY=true` — detect and report newer images, but never
  pull, recreate, or replace any container.
- `WATCHTOWER_NO_RESTART=true` — defence-in-depth: never restart running
  containers automatically.
- `WATCHTOWER_CLEANUP=false` — nothing is being replaced, so nothing is removed.
- `WATCHTOWER_SCHEDULE` — a **weekly** check (default Sundays 04:00 in your `TZ`),
  not an aggressive poll.
- The Docker socket is mounted **read-only** (`:ro`) — it only needs to inspect.

When an update is available it logs the finding and, if you set
`WATCHTOWER_NOTIFICATION_URL` (a [shoutrrr](https://containrrr.dev/shoutrrr/)
URL) in `.env`, sends a consolidated report. Upgrading then stays a deliberate,
reviewed action — pin the new tag in the compose file and re-deploy yourself.

---

## Reverse proxy

[`services/proxy/`](../services/proxy) holds the platform's single public entry
point: **[Caddy](https://caddyserver.com/)** (`caddy:2.8.4-alpine`, ARM64),
attached to the `proxy` network. It is the **only** container that binds host
ports — `80`, `443` (TLS) and `443/udp` (HTTP/3). Every other service stays
port-less and is reached through it.

### What it fronts

| Subdomain                  | Upstream           | Service     |
| -------------------------- | ------------------ | ----------- |
| `portainer.<BASE_DOMAIN>`  | `portainer:9000`   | Portainer   |
| `status.<BASE_DOMAIN>`     | `uptime-kuma:3001` | Uptime Kuma |

Subdomains are driven by `BASE_DOMAIN` from [`.env`](../.env.example). Routing
lives in [`services/proxy/Caddyfile`](../services/proxy/Caddyfile); WebSockets
(Uptime Kuma's live updates, Portainer's console) are proxied automatically.

### TLS — automatic, with a local fallback

Caddy provisions and renews certificates itself. Which kind depends on
`ACME_EMAIL`:

- **Local (default).** Leave `ACME_EMAIL` blank → Caddy issues **locally-
  trusted** certificates from its built-in **internal CA**. No public domain
  needed; works fully offline. With `BASE_DOMAIN` also blank it falls back to
  `localhost`, so the UIs answer at `https://portainer.localhost` /
  `https://status.localhost`.
- **Public.** Point a real, internet-resolvable `BASE_DOMAIN` at the Pi (ports
  80/443 reachable) and set `ACME_EMAIL` → Caddy obtains **public Let's
  Encrypt** certificates automatically and redirects HTTP → HTTPS.

> Compose collapses a blank `ACME_EMAIL` to the literal `internal` and a blank
> `BASE_DOMAIN` to `localhost` before handing them to Caddy, so the local
> fallback is the zero-config default.

Certificates and ACME account state persist in the `caddy_data` volume (so
restarts don't re-issue and risk Let's Encrypt rate limits); autosaved config
lives in `caddy_config`.

To trust the internal CA on another machine (local mode), export its root:

```bash
docker compose --env-file .env --project-directory . \
  -f infrastructure/docker-compose.yml \
  -f infrastructure/management.compose.yml \
  -f services/proxy/proxy.compose.yml \
  cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

then import `caddy-root.crt` into your OS/browser trust store. Note that
`*.localhost` resolves to loopback only **on the Pi itself** — to reach the UIs
from another machine, set `BASE_DOMAIN` to a name that resolves to the Pi
(public DNS, local DNS, or an `/etc/hosts` entry) and keep `ACME_EMAIL` blank
to stay on internal certs.

### Start it

```bash
# Brings up Caddy + the stack it fronts (base + management + proxy compose
# files together, so the shared network exists and the upstreams are up).
./scripts/start-proxy.sh
```

Equivalent manual command from the project root:

```bash
docker compose --env-file .env --project-directory . \
  -f infrastructure/docker-compose.yml \
  -f infrastructure/management.compose.yml \
  -f services/proxy/proxy.compose.yml \
  up -d
```

> `--project-directory .` keeps the relative `Caddyfile` bind-mount resolving
> against the project root regardless of which `-f` file is listed first.

---

## Databases

[`services/databases/`](../services/databases) provides an **on-demand** database
layer in a single file,
[`databases.compose.yml`](../services/databases/databases.compose.yml). Four
ARM64, version-pinned engines are defined, each behind its own **Docker Compose
profile**, so nothing here starts unless you explicitly ask for it — you bring up
**only the database(s) a given project needs**, never all four at once.

| Engine         | Image                 | Profile    | Reached internally as | Memory |
| -------------- | --------------------- | ---------- | --------------------- | ------ |
| **PostgreSQL** | `postgres:16.6-alpine`| `postgres` | `postgres:5432`       | 256M   |
| **MySQL**      | `mysql:8.4.3`         | `mysql`    | `mysql:3306`          | 512M   |
| **MongoDB**    | `mongo:7.0.14`        | `mongo`    | `mongo:27017`         | 512M   |
| **Redis**      | `redis:7.4.1-alpine`  | `redis`    | `redis:6379`          | 256M   |

All four tags are verified multi-arch including `linux/arm64/v8` (the Pi 5's
Cortex-A76). Memory limits are modest because you typically run only one or two
engines alongside the management/proxy stacks.

### The on-demand profile model

A service tagged with `profiles: [...]` is **inert** until its profile is
enabled. So a plain `up` brings up nothing in this file — you must pass the
matching `--profile` (or name the service). That is exactly what makes the layer
on-demand: PostgreSQL only runs when you ask for the `postgres` profile, Redis
only for `redis`, and so on. Each engine has its own named volume
(`postgres_data`, `mysql_data`, `mongo_data`, `redis_data`) so its data persists
independently across restarts.

### Start a single database

Use the helper — it passes the **base** compose file (so the shared `internal`
network resolves) together with the databases file and the **matching profile**:

```bash
./scripts/db.sh <engine> <action>
#   <engine>  postgres | mysql | mongo | redis
#   <action>  up | down | logs | status

# examples
./scripts/db.sh postgres up      # start PostgreSQL only
./scripts/db.sh redis status     # show the Redis container's status
./scripts/db.sh mongo logs       # follow MongoDB's logs
./scripts/db.sh mysql down       # stop + remove ONLY MySQL (its volume is kept)
```

- **`up`** starts just that engine (detached).
- **`down`** stops and removes **only that one container** (it uses a targeted
  `rm -s`, *not* `compose down`, so the rest of the platform is untouched). The
  engine's data volume is **preserved** — your data is safe.
- **`logs`** follows that engine's logs; **`status`** shows its container state.

Equivalent manual command (PostgreSQL shown):

```bash
docker compose --env-file .env \
  -f infrastructure/docker-compose.yml \
  -f services/databases/databases.compose.yml \
  --profile postgres up -d
```

Set credentials first in `.env` under the **DATABASES** section
([`.env.example`](../.env.example)) — fill in only the engine(s) you use. The
images take their users/passwords/db names strictly from those variables; none
are baked into the compose file.

### Internal-only, no host ports

Every database attaches to the **`internal`** network **only** — never `proxy` —
and publishes **no host ports**. Databases are not meant to be reachable from
outside the Pi; they are an east/west backend for your apps. Containers on
`internal` reach them by **service name** (e.g. `postgres:5432`), so there is no
host port to expose, scan, or firewall. (For ad-hoc admin from the Pi itself,
shell in with e.g. `docker exec -it pi-system_postgres psql -U <user> <db>`.)

### How an application service connects later

A future app service (a .NET API, a Next.js app, ...) lives in its own
`services/<app>/` folder, attaches to the **`internal`** network, and brings up
the database it needs via the same profile. It then connects over `internal`
using the **service name** as host — no IP addresses, no host ports. Examples:

```text
# .NET / Npgsql (PostgreSQL)
Host=postgres;Port=5432;Database=appdb;Username=appuser;Password=...

# Next.js / Prisma (PostgreSQL)
DATABASE_URL=postgresql://appuser:...@postgres:5432/appdb

# MongoDB
mongodb://appadmin:...@mongo:27017/appdb?authSource=admin

# Redis
redis://:<REDIS_PASSWORD>@redis:6379
```

> Both the app and the database must be on the `internal` network for name
> resolution to work — run the database profile, then start the app.

### .NET note: no SQL Server

Microsoft SQL Server — including **Azure SQL Edge** — is **not** reliably ARM64
on a Raspberry Pi (Edge is deprecated and never offered a dependable Pi build),
so it is deliberately **omitted** here. For .NET work on this platform, use
**PostgreSQL** as the primary relational database (first-class support via Npgsql
/ EF Core); MySQL is available as an alternative if a project requires it.

---

## Database admin UIs

[`services/db-admin/`](../services/db-admin) adds **optional, on-demand** visual
admin front-ends for the databases, in a single file,
[`db-admin.compose.yml`](../services/db-admin/db-admin.compose.yml). Like the
databases, each UI sits behind its own **Docker Compose profile**, so nothing
here starts unless you explicitly ask for it — bring a UI up only when you need
to poke at a database, then take it back down.

| Admin UI          | Image                   | Profile         | For        | Reach at (via Caddy)             | Memory |
| ----------------- | ----------------------- | --------------- | ---------- | -------------------------------- | ------ |
| **pgAdmin**       | `dpage/pgadmin4:8.14`   | `pgadmin`       | PostgreSQL | `https://pgadmin.<BASE_DOMAIN>`       | 256M |
| **Adminer**       | `adminer:4.8.1`         | `adminer`       | MySQL + PostgreSQL | `https://adminer.<BASE_DOMAIN>` | 128M |
| **Mongo Express** | `mongo-express:1.0.2`   | `mongo-express` | MongoDB    | `https://mongo-express.<BASE_DOMAIN>` | 256M |

All three tags are verified multi-arch including `linux/arm64`. **Redis is
intentionally left without a heavy GUI** — a web UI for a cache rarely earns its
memory on a Pi; `redis-cli` over `docker exec` covers it, and a small Redis UI
can be added later if a project ever needs one.

### Proxy-fronted, no host ports

Unlike the databases (which are `internal`-only), each admin UI attaches to
**both** networks: `internal` (to reach the database it manages by service name)
and `proxy` (so Caddy can front it). They still publish **no host ports** —
access is **only** through the reverse proxy over TLS, at the subdomains above.
So the proxy must be up (`./scripts/start-proxy.sh`) to reach them, and
`BASE_DOMAIN` defaults to `localhost` (e.g. `https://pgadmin.localhost`).

> The Caddyfile lists all three subdomains, but each upstream only exists while
> its profile is running. Caddy resolves these names at request time, so a UI
> that is down just returns **502** for its subdomain — it never blocks Caddy
> from starting.

### Start an admin UI

Use the helper — it passes the **base** compose file (so the shared `internal` /
`proxy` networks resolve) together with the db-admin file and the **matching
profile**:

```bash
./scripts/db-admin.sh <ui> <action>
#   <ui>      pgadmin | adminer | mongo-express
#   <action>  up | down | logs | status

# examples
./scripts/db-admin.sh pgadmin up         # start pgAdmin only
./scripts/db-admin.sh adminer status     # show the Adminer container's status
./scripts/db-admin.sh mongo-express logs # follow Mongo Express's logs
./scripts/db-admin.sh pgadmin down       # stop + remove ONLY pgAdmin (volume kept)
```

- **`up`** starts just that UI (detached) and prints its `https://<ui>.<BASE_DOMAIN>` URL.
- **`down`** stops and removes **only that one container** (targeted `rm -s`,
  *not* `compose down`). pgAdmin's `pgadmin_data` volume is **preserved**;
  Adminer and Mongo Express are stateless.
- **`logs`** follows that UI's logs; **`status`** shows its container state.

Equivalent manual command (pgAdmin shown):

```bash
docker compose --env-file .env \
  -f infrastructure/docker-compose.yml \
  -f services/db-admin/db-admin.compose.yml \
  --profile pgadmin up -d
```

### Start the matching database first

A UI is useless without its database running, so bring up the matching DB
profile **before** the UI (and Caddy must be up to reach it):

```bash
./scripts/db.sh postgres up         # then:  ./scripts/db-admin.sh pgadmin up
./scripts/db.sh mongo up            # then:  ./scripts/db-admin.sh mongo-express up
# Adminer fronts either relational engine — start postgres and/or mysql first.
```

### Credentials

Fill in only the UI(s) you use, under the **DATABASE ADMIN UIs** section of
[`.env.example`](../.env.example):

- **pgAdmin** — `PGADMIN_DEFAULT_EMAIL` (must be a valid e-mail format) and
  `PGADMIN_DEFAULT_PASSWORD` seed its first admin login. Inside pgAdmin, add a
  server pointing at host `postgres`, port `5432`, using your `POSTGRES_*` creds.
- **Adminer** — no credentials of its own; you enter the database login on its
  sign-in page (server `postgres` or `mysql`). `ADMINER_DEFAULT_SERVER`
  optionally pre-fills the Server field.
- **Mongo Express** — `ME_CONFIG_BASICAUTH_USERNAME` / `ME_CONFIG_BASICAUTH_PASSWORD`
  protect the **UI itself** (required, since it is internet-facing via Caddy). It
  connects to MongoDB by **reusing** the `MONGO_INITDB_ROOT_USERNAME` /
  `MONGO_INITDB_ROOT_PASSWORD` you already set in the DATABASES section.

> pgAdmin runs behind Caddy with `PGADMIN_CONFIG_PROXY_X_*` set so it honours the
> reverse proxy's forwarded headers (correct HTTPS scheme/host for logins and
> CSRF). No extra configuration is needed for Adminer or Mongo Express.

---

## Authentication (Keycloak)

[`services/auth/`](../services/auth) adds a centralized **identity provider** —
**[Keycloak](https://www.keycloak.org/)** (`quay.io/keycloak/keycloak:26.6.2`,
ARM64) — so that a **single login** can later guard the platform's UIs and apps
over **OIDC / OAuth2 / SAML**. This phase only stands Keycloak up; wiring
individual services behind it (realms, clients, redirect URIs) comes later.

| Service        | Image                              | Network(s)           | Reach at (via Caddy)        | Memory |
| -------------- | ---------------------------------- | -------------------- | --------------------------- | ------ |
| **Keycloak**   | `quay.io/keycloak/keycloak:26.6.2` | `internal` + `proxy` | `https://auth.<BASE_DOMAIN>` | 768M  |
| **keycloak-db**| `postgres:16.6-alpine`             | `internal`           | *(internal only)*           | 256M  |

Both tags are verified multi-arch including `linux/arm64` (the Pi 5's Cortex-A76).

### Its own isolated database

Keycloak does **not** use the shared engines in
[`services/databases/`](../services/databases). It gets a **dedicated**
PostgreSQL instance, `keycloak-db`, on the `internal` network only, with **no
host ports** and its **own** named volume (`keycloak_db_data`). An identity
store has a different lifecycle and blast radius than application data, so it is
kept completely separate — Keycloak reaches it privately as `keycloak-db:5432`.
The three `KC_DB_*` values in `.env` configure both the database (as its
`POSTGRES_*`) and Keycloak's connection to it.

### Proxy-fronted, no host ports

Keycloak attaches to **both** networks — `internal` (to reach `keycloak-db`) and
`proxy` (so Caddy fronts it) — but publishes **no host ports**. It is configured
for a reverse-proxy deployment: it runs in **production mode** (`start`), trusts
Caddy's forwarded headers (`KC_PROXY_HEADERS=xforwarded`; Caddy sets
`X-Forwarded-For/Proto/Host` by default), and accepts the internal HTTP hop
(`KC_HTTP_ENABLED=true`) since Caddy terminates TLS upstream. Caddy routes
`auth.<BASE_DOMAIN>` → `keycloak:8080`, so the proxy must be up
(`./scripts/start-proxy.sh`) to reach it; with `BASE_DOMAIN` blank it answers at
`https://auth.localhost`.

> **Hostname.** Leave `KC_HOSTNAME` blank for local use — Keycloak derives the
> host/scheme from Caddy's forwarded headers. For **public** use, set
> `KC_HOSTNAME=https://auth.<your-domain>` so issued tokens and redirects use a
> fixed, correct address.

### ⚠ Higher memory footprint on the Pi

Keycloak is **JVM-based and the heaviest service in pi-system so far** — its
**768M** limit is several times that of the others, with the JVM heap capped
(`JAVA_OPTS_KC_HEAP=-Xms256m -Xmx512m`) to stay inside it. First boot is also
**slow on a Pi**, because production mode re-augments the server before it
serves traffic. Treat it as **on-demand**: bring it up when you need SSO and
**take it down when idle** to free ~¾ GB of RAM:

```bash
./scripts/auth.sh down     # stops Keycloak + keycloak-db; identity data is kept
```

### Start it

Use the helper — it passes the **base** compose file (so the shared `internal` /
`proxy` networks resolve) together with the auth file, and brings up Keycloak
**and** its database as a unit:

```bash
./scripts/auth.sh <action>
#   <action>  up | down | logs | status

# examples
./scripts/auth.sh up        # start keycloak-db + keycloak (be patient on first boot)
./scripts/auth.sh logs      # follow startup progress (Ctrl-C to stop)
./scripts/auth.sh status    # show the auth containers' state
./scripts/auth.sh down      # stop + remove ONLY the auth containers (volume kept)
```

- **`up`** starts both containers (detached) and warns that first boot is slow.
- **`down`** stops and removes **only** the two auth containers (targeted
  `rm -s`, *not* `compose down`). The `keycloak_db_data` volume is **preserved**
  — all realms, users and clients survive.
- **`logs`** follows both containers' logs; **`status`** shows their state.

Equivalent manual command from the project root:

```bash
docker compose --env-file .env \
  -f infrastructure/docker-compose.yml \
  -f services/auth/auth.compose.yml \
  up -d
```

Set credentials first in `.env` under the **AUTHENTICATION (KEYCLOAK)** section
([`.env.example`](../.env.example)): the `KC_DB_*` database trio and the
`KC_BOOTSTRAP_ADMIN_*` initial admin login. Keycloak takes all of these strictly
from the environment; none are baked into the compose file.

### First login & bootstrap

1. Start the proxy and the auth stack: `./scripts/start-proxy.sh` then
   `./scripts/auth.sh up`. Wait for the first-boot augmentation to finish
   (`./scripts/auth.sh logs` until you see Keycloak listening).
2. Open `https://auth.<BASE_DOMAIN>` (e.g. `https://auth.localhost`) and sign in
   to the **Administration Console** with `KC_BOOTSTRAP_ADMIN_USERNAME` /
   `KC_BOOTSTRAP_ADMIN_PASSWORD`.
3. Create a **permanent** admin user (in the `master` realm), then **disable or
   remove** the temporary bootstrap admin — it is only meant for first setup.
4. Create a **realm** for the platform (e.g. `pi-system`) and, later, **clients**
   for each app/UI you put behind SSO (with their redirect URIs). That wiring is
   a future phase — this phase only stands Keycloak up.

> The bootstrap admin credentials are read **on first startup** to seed the
> initial account. Rotate them by managing users inside Keycloak rather than
> relying on those env vars long-term.

---

## Automation (n8n)

[`services/automation/`](../services/automation) adds the platform's central
**workflow automation engine** — **[n8n](https://n8n.io/)**
(`n8nio/n8n:2.21.7`, ARM64) — so platform tasks can run on a schedule or react to
webhooks and orchestrate the other services from one place. This phase brings n8n
up (with its own database) and ships **one** internal-operations workflow:
platform **health monitoring + alerting**.

| Service     | Image                  | Network(s)           | Reach at (via Caddy)               | Memory |
| ----------- | ---------------------- | -------------------- | ---------------------------------- | ------ |
| **n8n**     | `n8nio/n8n:2.21.7`     | `internal` + `proxy` | `https://automation.<BASE_DOMAIN>` | 512M   |
| **n8n-db**  | `postgres:16.6-alpine` | `internal`           | *(internal only)*                  | 256M   |

Both tags are verified multi-arch including `linux/arm64` (the Pi 5's Cortex-A76).

### What it's for here

n8n is the platform's **internal automation brain**: scheduled maintenance,
health checks, glue between services, and reacting to webhooks — all without
hand-rolled cron scripts. The bundled workflow demonstrates real value by
watching the platform itself (see [the workflow](#the-bundled-workflow--platform-health-alert)
below).

> **Client-acquisition workflows are intentionally deferred.** Scraping,
> cold-outreach and other third-party data-harvesting automations touch
> legal / ToS-sensitive areas and are **deliberately not built in this phase**,
> pending a legal/ToS review. This phase keeps the scope to the n8n service plus
> the one internal-operations (health/alerting) workflow.

### Its own isolated database

Like Keycloak, n8n does **not** use the shared engines in
[`services/databases/`](../services/databases) (nor `keycloak-db`). It gets a
**dedicated** PostgreSQL instance, `n8n-db`, on the `internal` network only, with
**no host ports** and its **own** named volume (`n8n_db_data`). n8n's
workflow/execution data has its own lifecycle and blast radius, so it stays
completely separate — n8n reaches it privately as `n8n-db:5432`. The three
`N8N_DB_*` values in `.env` configure both the database (as its `POSTGRES_*`) and
n8n's connection to it. n8n's own data directory (`/home/node/.n8n`) persists in
the `n8n_data` volume.

### Proxy-fronted, no host ports (reverse-proxy / edge mode)

n8n attaches to **both** networks — `internal` (to reach `n8n-db` **and** the
platform services it monitors) and `proxy` (so Caddy fronts it) — but publishes
**no host ports**. It is configured for an **edge / reverse-proxy** deployment so
the editor, the webhook URLs it registers, and its session cookie all build/work
correctly behind Caddy:

- `N8N_PROTOCOL=https` + `WEBHOOK_URL` / `N8N_EDITOR_BASE_URL` — n8n builds
  absolute **https** URLs from these (not from the internal http hop), so
  production webhook URLs are correct behind the proxy.
- `N8N_PROXY_HOPS=1` — exactly one reverse proxy (Caddy) sits in front, so n8n
  trusts a single set of `X-Forwarded-*` headers (correct client IP / proto).
- `N8N_SECURE_COOKIE=true` — the session cookie is `Secure`; the browser only
  sends it over https (which Caddy serves, even locally via its internal CA).

Caddy routes `automation.<BASE_DOMAIN>` → `n8n:5678`, so the proxy must be up
(`./scripts/start-proxy.sh`) to reach it; with `BASE_DOMAIN` blank it answers at
`https://automation.localhost`. WebSockets (the editor's push channel) are
proxied automatically.

> **Hostname / webhooks.** Leave `N8N_HOST` and `N8N_WEBHOOK_URL` blank for local
> use (they default to `automation.localhost` / `https://automation.localhost/`).
> For **public** use, set `N8N_HOST=automation.<your-domain>` and
> `N8N_WEBHOOK_URL=https://automation.<your-domain>/` so registered webhook URLs
> and editor links use a fixed, correct public address.

### Access control

n8n's **own built-in user management** guards the editor: on first visit you
create an **owner account** (email + password) — there is no anonymous access,
and modern n8n no longer offers env-based basic auth. Since n8n binds **no host
ports**, it is only ever reachable through Caddy regardless. You can optionally
layer **Caddy `basic_auth`** or **Keycloak** in front of `automation.<BASE_DOMAIN>`
later for an extra gate.

### ⚠ N8N_ENCRYPTION_KEY — back it up, never lose it

n8n encrypts **every stored credential** with `N8N_ENCRYPTION_KEY`. This key must
stay **stable and secret** for the life of the instance:

- **Lose or change it** → every saved credential becomes permanently
  **unrecoverable**.
- **Leak it** → stored credentials can be decrypted by anyone who has it.

It is supplied from `.env` only (never committed). Generate it **once** and keep a
copy **offline** alongside your other keys (like the backup `age` key):

```bash
openssl rand -hex 32      # paste into N8N_ENCRYPTION_KEY in .env
```

[`check-secrets.sh`](../scripts/check-secrets.sh) flags a missing/empty
`N8N_ENCRYPTION_KEY` as **critical** (the same severity as an unauthenticated
Redis or a missing backup key), because losing it silently destroys credential
recoverability.

### Resource footprint on the Pi

n8n is a **moderately heavy** Node.js service. Its **512M** limit is a baseline
sized for light internal workflows like the bundled health check — raise it for
heavier automations or external task runners. With `n8n-db`'s 256M the stack
costs ~768M; lighter than Keycloak but still meaningful, so treat it as
**on-demand** and take it down when idle:

```bash
./scripts/automation.sh down     # stops n8n + n8n-db; workflow/credential data is kept
```

### Start it

Use the helper — it passes the **base** compose file (so the shared `internal` /
`proxy` networks resolve) together with the automation file, and brings up n8n
**and** its database as a unit:

```bash
./scripts/automation.sh <action>
#   <action>  up | down | logs | status

# examples
./scripts/automation.sh up        # start n8n-db + n8n (first boot runs migrations — be patient)
./scripts/automation.sh logs      # follow startup progress (Ctrl-C to stop)
./scripts/automation.sh status    # show the automation containers' state
./scripts/automation.sh down      # stop + remove ONLY the automation containers (volumes kept)
```

- **`up`** starts both containers (detached) and warns that first boot is slow.
- **`down`** stops and removes **only** the two automation containers (targeted
  `rm -s`, *not* `compose down`). The `n8n_db_data` + `n8n_data` volumes are
  **preserved** — all workflows and credentials survive.
- **`logs`** follows both containers' logs; **`status`** shows their state.

Equivalent manual command from the project root:

```bash
docker compose --env-file .env \
  -f infrastructure/docker-compose.yml \
  -f services/automation/automation.compose.yml \
  up -d
```

Set credentials first in `.env` under the **AUTOMATION (n8n)** section
([`.env.example`](../.env.example)): the `N8N_DB_*` database trio, the critical
`N8N_ENCRYPTION_KEY`, and optionally `N8N_HOST` / `N8N_WEBHOOK_URL` for public
use. n8n takes all of these strictly from the environment; none are baked into
the compose file. On first visit to `https://automation.<BASE_DOMAIN>`, create
the owner account.

### The bundled workflow — platform-health-alert

[`automation/workflows/platform-health-alert.json`](../automation/workflows/platform-health-alert.json)
is an importable, self-contained workflow that proves n8n's value by watching the
platform:

```
Schedule Trigger ──▶ Check platform services ──▶ Any service down? ──┬─(true)─▶ Send alert (configure me)
   every 5 min          (HTTP health checks)          (IF)            └─(false)▶ All healthy
```

On a schedule it makes an internal HTTP request to each key service (by Docker
service name — n8n is on both networks, so no host ports are needed), decides
healthy/unhealthy, and on failure fires a **swappable** notification step. The
default notifier is a safe **no-op**, and the check node always logs its result,
so the n8n execution log / `./scripts/automation.sh logs` is a zero-config alert
channel even before you wire a real notifier.

**Import it** (n8n does not auto-load workflows): in the n8n editor →
**Import from File** → choose
`automation/workflows/platform-health-alert.json` → **Save** → toggle **Active**.

**Point it at a real notifier later, with no secrets in git:** replace the
*Send alert (configure me)* node with a **Telegram**, **Send Email**, or
**HTTP Request** (Slack/Discord/generic webhook) node, and keep every token /
webhook URL in an n8n **credential** or **environment variable** (e.g.
`={{ $env.ALERT_WEBHOOK_URL }}`) — never hard-coded into the committed workflow.
Full how-to (including tuning the target list and schedule, and the alternative
of reading Uptime Kuma's API):
[`automation/workflows/README.md`](../automation/workflows/README.md).

---

## Telegram management bot

A **lightweight, operator-only** bot that lets you monitor and control the
platform from Telegram — receive alerts, query status, and trigger a **safe,
whitelisted** set of actions — from your phone. It is built **on top of** what
already exists: it runs as an n8n **workflow**
([`automation/workflows/telegram-management-bot.json`](../automation/workflows/telegram-management-bot.json))
plus a thin, audited host bridge
([`scripts/bot-exec.sh`](../scripts/bot-exec.sh)) that **orchestrates** the
existing tools (`scripts/pi`, `scripts/status.sh`, `scripts/project.sh`). There is
**no new always-on container, no heavy framework, and no paid AI** — every command
is deterministic command logic.

### What it can do (whitelist only)

| Command | Kind | Runs |
| --- | --- | --- |
| `/status` | read-only | `scripts/pi status` — whole-system snapshot |
| `/health` | read-only | `scripts/pi health` — host hardware health |
| `/check` | read-only | `scripts/pi check` — preflight + memory budget |
| `/projects` | read-only | list generated projects + their state |
| `/up <profile>` | state-changing | `scripts/pi up --profile <p>` (`core`·`dev`·`auth`·`automation`; default `core`) |
| `/down <profile>` | state-changing | `scripts/pi down --profile <p>` |
| `/project_up <name>` | state-changing | `scripts/project.sh up <name>` |
| `/project_down <name>` | state-changing | `scripts/project.sh down <name>` |
| `/help` | — | the command list (answered in-workflow) |

Anything not in this list is refused. Read-only commands never change state;
state-changing commands are **logged** by the bridge.

### The strict allowlist security model

This bot can start and stop services, so it is locked down deliberately:

- **Allowlist, fail closed.** The workflow's *Authorize* node only proceeds when
  the sender's numeric Telegram id is in `TELEGRAM_ALLOWED_IDS`. A missing id, an
  **empty** allowlist, or a blank one authorizes **no one** — it is never an open
  bot. Unknown senders get a polite denial (delete the false-branch reply link to
  go fully silent).
- **Whitelist only.** Only the commands above are accepted; everything else is
  refused with `/help`.
- **n8n never runs arbitrary host commands.** n8n is *not* given the Docker socket
  or the host filesystem. It reaches the host **only** through `bot-exec.sh` over
  SSH using a **dedicated key**. That script (`set -euo pipefail`) accepts only the
  fixed action set, validates every argument (profile against an allowlist; project
  name against the shape **and** the set of real generated projects), **logs every
  invocation**, and **never evals** input — it is the real security boundary, even
  if the workflow is changed. Validation happens in **both** places (defence in
  depth).
- **No secrets in replies, none in git.** The bot **token** lives in an n8n
  *credential*; the **allowlist** lives in `.env`. The committed workflow JSON and
  the bridge script contain no secrets, and the read-only tools the bridge calls
  never print secrets.

```
Telegram → Authorize, parse & plan → Execute on host? ─┬─(true)→ Run bot-exec.sh (SSH) → Reply: command result
  (your bot)   (allowlist + whitelist, no AI)          └─(false)→ Reply: message (denial / help / unknown / error)
```

The whole decision layer is pure logic in
[`scripts/lib/bot-lib.sh`](../scripts/lib/bot-lib.sh) (the workflow's Code node
mirrors it) and is covered offline — without Docker, n8n or Telegram — by
[`tests/bot/`](../tests/bot).

### Alerts and control share one channel

The bundled [health-alert workflow](#the-bundled-workflow--platform-health-alert)
ships a **disabled** *Notify Telegram (optional — enable me)* node already wired to
its failure branch. Enable it and pick the same Telegram credential, and platform
**alerts** (health/backup/failures) land in the **same** chat you **control** the
platform from — one channel for both. It targets the first id in
`TELEGRAM_ALLOWED_IDS` and embeds no secret.

### Audit log

Every bridge call — accepted or refused — is appended to
`./data/bot/bot-exec.log` (override with `TELEGRAM_BOT_EXEC_LOG`) as a
tab-separated line: timestamp, action, argument, read-only/state-changing class,
and the result (`ACCEPTED`/`REFUSED`/`DRYRUN`/`EXIT:<code>`). State-changing
actions are therefore always traceable.

### ⚠ One-time manual setup (deferred operator step)

Creating the bot needs an external account (Telegram), so this is a **deferred,
manual** step done once on the Pi — nothing here is automatic:

1. **Create the bot.** In Telegram, message **@BotFather**, run `/newbot`, and
   copy the **HTTP API token** it gives you.
2. **Find your user id.** Message **@userinfobot** (or similar) to get your
   **numeric** Telegram user id.
3. **Set env.** In `.env` (see the **TELEGRAM BOT** section of
   [`.env.example`](../.env.example)) set
   `TELEGRAM_ALLOWED_IDS=<your id>` (comma-separate several), optionally
   `TELEGRAM_BOT_TOKEN`, and `PI_BOT_EXEC` if your install path is not
   `/opt/pi-system/scripts/bot-exec.sh`. Restart n8n so it picks up the env:
   `./scripts/automation.sh down && ./scripts/automation.sh up`.
   [`check-secrets.sh`](../scripts/check-secrets.sh) **warns** if a token is set
   while the allowlist is empty (an open control channel).
4. **Import the workflow.** In the n8n editor → **Import from File** →
   `automation/workflows/telegram-management-bot.json`. Create a **Telegram API**
   credential (the BotFather token) and select it on the **Telegram Trigger** and
   both **Reply** nodes.
5. **Wire the host bridge (SSH).** Create a dedicated key for n8n, add it as an
   n8n **SSH** credential, and select it on the *Run bot-exec.sh on host* node.
   **Recommended hardening:** pin that key to a forced command in the Pi's
   `~/.ssh/authorized_keys` so it can *only* ever launch the bridge — the requested
   action arrives in `$SSH_ORIGINAL_COMMAND`, which `bot-exec.sh --from-ssh`
   re-validates:

   ```
   command="bash /opt/pi-system/scripts/bot-exec.sh --from-ssh",no-pty,no-port-forwarding,no-X11-forwarding,no-agent-forwarding ssh-ed25519 AAAA…n8n-bot
   ```

   The bot's OS user needs permission to run Docker (the `docker` group or scoped
   `sudo` for the helper scripts) — that is the inherent power of the bot, kept
   behind the Telegram allowlist **and** the bridge's validation.
6. **Activate.** **Save** the workflow and toggle it **Active**. Send `/help` from
   an allowlisted account to confirm; send it from another account to confirm the
   denial.

> **No paid AI is involved.** The bot is plain, deterministic command logic — no
> model calls, no API keys, no per-message cost.

For the node-by-node walkthrough and the bridge's full contract, see
[`automation/workflows/README.md`](../automation/workflows/README.md).

---

## Dashboard (Homepage)

A single landing page that fronts **every** platform service with cards, links
and at-a-glance health, so there is one place to jump to Portainer, Uptime Kuma,
Keycloak, n8n, the database admin UIs and any generated project. It is
[Homepage](https://gethomepage.dev/) (`ghcr.io/gethomepage/homepage:v1.13.1`,
multi-arch incl. `linux/arm64`), a lightweight, file-configured dashboard.

Like every other UI it publishes **no host ports** and is reached only through
Caddy, at `home.<BASE_DOMAIN>` (e.g. `https://home.localhost` locally). It sits
on **both** networks: `proxy` so Caddy can front it, and `internal` so its
health checks can reach the other services by name.

### Configuration is committed, not hidden in a volume

Homepage's whole configuration is the version-controlled YAML under
[`services/dashboard/config/`](../services/dashboard/config/) — bind-mounted to
`/app/config` (a **mounted directory**, deliberately *not* a named volume, so the
layout lives in the repo and is reviewable in a diff):

| File | What it holds |
| ---- | ------------- |
| `settings.yaml`  | Title, theme, group layout |
| `services.yaml`  | The service cards (links + secret-free HTTP health) |
| `widgets.yaml`   | Top info widgets (search, clock, resources) |
| `bookmarks.yaml` | Quick links |
| `docker.yaml`    | Docker-socket integration — **disabled by default** |

Edit a file, then `./scripts/dashboard.sh up` (or just refresh — Homepage
re-reads its YAML per request).

### No secrets, and no privileged socket

Service URLs are built at runtime from `${BASE_DOMAIN}` via Homepage's
`{{HOMEPAGE_VAR_BASE_DOMAIN}}` substitution, so the same committed files work
locally and in production with no edits. Health is plain, credential-free HTTP
probes (`siteMonitor`) over the internal network — the Docker socket is **not**
mounted. Any widget that *would* need an API key (e.g. the optional Portainer
container-count widget) ships **commented out** and takes its key from a
`HOMEPAGE_VAR_*` variable in `.env` (see the `DASHBOARD (Homepage)` section of
`.env.example`) — never from committed config.

> Since v1.0 Homepage rejects requests whose `Host` header is not allow-listed.
> The compose file sets `HOMEPAGE_ALLOWED_HOSTS=home.${BASE_DOMAIN}` for you, so
> it tracks your domain automatically with no manual step.

### Start it

```bash
./scripts/dashboard.sh <action>

#   <action>  up | down | logs | status

# examples
./scripts/dashboard.sh up        # start Homepage (reachable via Caddy)
./scripts/dashboard.sh status
./scripts/dashboard.sh down      # remove the container; committed config is kept
```

Make sure Caddy is up (`./scripts/start-proxy.sh`) to actually open
`https://home.<BASE_DOMAIN>`. To add a generated project to the dashboard, copy
the commented example under the **Projects** group in
[`services/dashboard/config/services.yaml`](../services/dashboard/config/services.yaml).
More detail in [`services/dashboard/README.md`](../services/dashboard/README.md).

---

## Templates & project generator

Once the platform (proxy, databases, auth) is in place, new **client projects**
are scaffolded from a **three-layer template system** instead of being wired by
hand. [`scripts/new-project.sh`](../scripts/new-project.sh) stamps a project into
`services/<name>/`, **pre-wired for this platform**: Dockerized for ARM64
(multi-stage), connected to a chosen database by service name, published through
Caddy, bilingual-ready, and ready to be put behind Keycloak.

### Three layers: base, modules, presets

The [`templates/`](../templates) directory is organized so that *what every
project shares* is separated from *what varies* — giving low-maintenance variety
across many client sites. Full write-up:
[`templates/docs/README.md`](../templates/docs/README.md).

| Layer       | What it is                                                        | This phase ships                                        |
| ----------- | ---------------------------------------------------------------- | ------------------------------------------------------- |
| **base**    | the shared scaffold a project is built from                      | `dotnet-api`, `nextjs-app`, `fullstack` (working)       |
| **modules** | composable features layered on a base                           | the contract, the `hello-module` reference, and **six** real modules `i18n-bilingual` + `content-admin` + `bookings` + `auth-sso` + `whatsapp-integration` + `local-payments` (no feature modules left planned) |
| **presets** | sector recipes = one base + a set of modules                    | the contract + 4 `status: available` stubs (each composes the implemented modules it lists) |

The base shapes:

| Base shape   | Stack                                   | Web-facing service        | Default use                              |
| ------------ | --------------------------------------- | ------------------------- | ---------------------------------------- |
| `dotnet-api` | .NET Web API (current LTS), minimal     | the API (`:8080`)         | a backend / JSON API                     |
| `nextjs-app` | Next.js (App Router, standalone output) | the app (`:3000`)         | a web frontend / SSR app                 |
| `fullstack`  | .NET API **+** Next.js                  | the frontend (`:3000`)    | frontend that calls an internal API      |

Every base shape ships a **multi-stage Dockerfile** with pinned, ARM64-compatible
base images (.NET 10 LTS, Node 22 LTS — never `latest`), a small runtime image,
a non-root user, a `/health` endpoint, and a compose **fragment** with no host
ports, a memory limit, `restart: unless-stopped` and `no-new-privileges`.

> **Security maintenance — Next.js pin.** The base (and any module that ships a
> frontend, e.g. `auth-sso`) pins **`next@15.5.18`**, with React/react-dom at
> `19.0.0`. Because the pin lives in the template, **every project generated from
> now on inherits it** — a base-level fix that propagates automatically, rather
> than something to patch per project. This release remediates **CVE-2025-66478**
> (Next.js App Router RSC remote code execution; the earlier `next@15.1.0` pin was
> affected). It is the latest stable, secure 15.x — superseding the `15.5.7`
> advisory patch — and was verified by building a generated `fullstack` *and*
> `nextjs-app` project with the full module set cleanly on the new pin. See
> [`templates/base/README.md`](../templates/base/README.md#dependency-security-maintenance--a-base-concern).

The four sector presets (declaration-only stubs; every module they list is now
implemented and composed — the two credentialed ones run on a mock provider by
default):

| Preset         | Base         | Composes (all implemented)                                               |
| -------------- | ------------ | ------------------------------------------------------------------------ |
| `clinic`       | `fullstack`  | bookings, content-admin, i18n-bilingual, auth-sso, whatsapp-integration |
| `ecommerce`    | `fullstack`  | local-payments, content-admin, i18n-bilingual, whatsapp-integration |
| `company-site` | `nextjs-app` | content-admin, i18n-bilingual _(no auth-sso — public site)_       |
| `real-estate`  | `fullstack`  | bookings, content-admin, i18n-bilingual, auth-sso, whatsapp-integration |

> **All six feature modules are now built.** `i18n-bilingual` (Arabic/English + RTL),
> `content-admin` (a [Directus](https://directus.io) headless CMS), `bookings`
> (appointment / reservation scheduling), `auth-sso` (optional Keycloak SSO),
> `whatsapp-integration` (WhatsApp messaging) and `local-payments` (mada / card
> checkout) are all `implemented`, so every preset above composes the ones it lists
> automatically. `content-admin` adds the CMS as an `internal`-only container with
> its own private database (no host ports); set its `CMS_*` secrets in `.env` and
> reach the `/admin` UI over an SSH tunnel. `bookings` adds **no container** — it
> layers a small .NET API + a bilingual Next.js booking UI into the base's existing
> services and uses the **project's own** PostgreSQL, preventing double-booking
> server-side. `auth-sso` is **optional** (never forced — `company-site` omits it):
> real OIDC (Authorization Code + PKCE on the frontend, JWT bearer validation on the
> backend) against the **existing Keycloak**, with a deferred one-time Keycloak step
> in its [SETUP.md](../templates/modules/auth-sso/SETUP.md).
>
> **`whatsapp-integration` and `local-payments` use a swappable-provider design.**
> Each ships **one internal interface** with a **mock / sandbox provider active by
> default** and a **real** provider (the WhatsApp Cloud API; Moyasar — mada / Apple
> Pay / cards) that is fully coded but **inert until credentials are set**. So they
> **compose, build and run now** with no external account — the mock makes the whole
> flow testable, and `local-payments` even simulates the full lifecycle locally
> (create → pay → **signature-verified, idempotent** webhook → paid). Going **live**
> is a one-time, operator-run step (a Meta / WhatsApp Business account; a Moyasar
> merchant account) documented in each module's `SETUP.md` and **deferred to the
> final manual session** — flipping `WHATSAPP_PROVIDER` / `PAYMENTS_PROVIDER` (plus
> the keys) in `.env` is the only change. No feature modules remain planned.

### Scaffold a project

```bash
# From a sector preset (it declares base, db, locale and the module list):
./scripts/new-project.sh --name happy-teeth --preset clinic --subdomain teeth

# Or manually: a base shape + an optional explicit module list:
./scripts/new-project.sh --name acme --base fullstack --db postgres \
  --subdomain acme --locale ar --modules hello-module

#   --name        lowercase, letter first, [a-z0-9-], 2-40 chars (also the service name)
#   --preset      clinic | ecommerce | company-site | real-estate
#   --base        dotnet-api | nextjs-app | fullstack   (alias: --template)
#   --modules     comma/space list (added to a preset's list); names validated
#   --db          postgres | mysql | mongo | none
#   --subdomain   DNS label for the public subdomain (defaults to <name>)
#   --locale      ar | en  (default locale; ar => RTL. Default: ar, or the preset's)
```

Pass **either** `--preset` (which supplies the base, db, locale and modules, each
overridable by its own flag) **or** `--base` directly. Run with no flags (on a
terminal) and it **prompts** for the missing values. It **validates** every input
(name, preset, base, db, locale, subdomain, module names) and **never overwrites**
an existing `services/<name>/` without `--force` (which first moves the old folder
aside to `services/<name>.bak-<timestamp>`).

What the generator does, in one pass:

1. **Resolves** the inputs (a preset fills base/db/locale/modules; flags override;
   `--modules` are added on top).
2. **Copies** `templates/base/<shape>/` into `services/<name>/` and substitutes the
   placeholders (`__PROJECT_NAME__`, `__SUBDOMAIN__`, `__DB_ENGINE__`, the DB
   connection string, the per-project env prefix, and the bilingual
   `__DEFAULT_LOCALE__` / `__DEFAULT_DIR__`). The main fragment
   `service.compose.yml` is renamed to `<name>.compose.yml`, wired to the shared
   `internal` (and, for web parts, `proxy`) networks with **no host ports**.
3. **Composes modules**: each **implemented**, base-compatible module is wired in
   (its empty env templates appended, its `files:` source tree copied into the
   project, its compose fragment copied to
   `services/<name>/<name>.<module>.compose.yml`, its Caddy routes injected, and it
   is listed as *active*); each **planned** module is skipped and recorded as a
   TODO; an **implemented module that doesn't support the chosen base** (e.g.
   `i18n-bilingual` on a `dotnet-api` base) is skipped and recorded under *Modules
   not applied*, pointing to its alternative — so the project is never left broken.
4. **Appends** an env-driven Caddy block to
   [`services/proxy/Caddyfile`](../services/proxy/Caddyfile) following the
   existing pattern — `<sub>.{$BASE_DOMAIN} → <service>:<port>` — idempotently,
   plus a clearly-commented, **empty** per-project section to
   [`.env.example`](../.env.example) (`<NAME>_APP_SECRET`,
   `<NAME>_OIDC_CLIENT_ID`, `<NAME>_OIDC_CLIENT_SECRET`, plus any active-module
   env templates) — templates only, never real values.
5. **Writes** `services/<name>/PROJECT.md` (summary + active modules + planned
   TODOs, flagging any needing external credentials), **validates** the merged
   compose (when Docker + `.env` are present), and prints the next steps.

### How database selection wires the connection

You pick the engine with `--db`; the generator builds the connection from the
**shared** credentials already in `.env` (the `DATABASES` section) and injects it
into the service — nothing new to set for the DB itself. The app reaches the
database **by service name** over the `internal` network:

| `--db`     | Reached as     | .NET (`ConnectionStrings__Default`)                                   | URL form (`DATABASE_URL`)                       |
| ---------- | -------------- | -------------------------------------------------------------------- | ----------------------------------------------- |
| `postgres` | `postgres:5432`| `Host=postgres;…;Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}` | `postgresql://…@postgres:5432/${POSTGRES_DB}` |
| `mysql`    | `mysql:3306`   | `Server=mysql;…;User ID=${MYSQL_USER};Password=${MYSQL_PASSWORD}`     | `mysql://…@mysql:3306/${MYSQL_DATABASE}`        |
| `mongo`    | `mongo:27017`  | `mongodb://…@mongo:27017/${MONGO_INITDB_DATABASE}?authSource=admin`   | same Mongo URI                                  |
| `none`     | —              | empty                                                                | empty                                           |

The `${...}` tokens stay literal in the compose file and are interpolated by
Compose from `.env` at runtime, so **no secret is ever written into a committed
file**. The `dotnet-api` base reads `ConnectionStrings__Default`; the `nextjs-app`
base reads `DATABASE_URL`; in `fullstack`, only the **backend** talks to the DB
while the **frontend** calls the backend over the internal network at
`http://<name>-api:8080`.

### Bilingual / RTL & extending the system

Projects are **Arabic-first bilingual-ready** by base convention: `--locale ar|en`
(or a preset's `default_locale`) stamps `<html lang dir>` (RTL for Arabic) and a
`DEFAULT_LOCALE` env var into every service. The now-**implemented**
`i18n-bilingual` module builds on that hook: add `--modules i18n-bilingual` (or use
any preset — all four list it) for live language switching, message catalogues and
locale-prefixed routes (`/ar`, `/en`). To add your own **module** or **sector preset**,
follow the contracts in [`templates/modules/README.md`](../templates/modules/README.md)
and [`templates/presets/README.md`](../templates/presets/README.md); the
philosophy and step-by-step guides are in
[`templates/docs/README.md`](../templates/docs/README.md).

### Run a generated project

```bash
./scripts/db.sh <engine> up            # start its database first (skip if --db none)
./scripts/start-proxy.sh               # ensure Caddy is up (re-reads the Caddyfile)
./scripts/project.sh up <name>         # build + start the project (base + its fragment + any module fragments)
```

`project.sh` mirrors the other helpers:

```bash
./scripts/project.sh <action> <name>
#   up      build (if needed) and start the project (detached)
#   down    stop + remove ONLY this project's container(s) (shared networks kept)
#   logs    follow this project's logs
#   status  show this project's container status
```

It runs the **base** compose file together with the project's main fragment —
plus any module fragments (`services/<name>/<name>.*.compose.yml`) — so the shared
networks resolve and every part of the project starts together. Then browse
`https://<sub>.<BASE_DOMAIN>` (e.g. `https://acme.localhost`). If Caddy was
already running when you scaffolded, reload it so the new subdomain is served:

```bash
docker exec pi-system_caddy caddy reload --config /etc/caddy/Caddyfile
# (or simply re-run ./scripts/start-proxy.sh)
```

### Putting a project behind Keycloak — the `auth-sso` module

This is now a **composable module**, not hand-written per project. Add
`--modules auth-sso` (or use a preset that lists it — `clinic`, `real-estate`) and
the generator wires **real OIDC** end to end: the **Authorization Code flow with
PKCE** + an encrypted session on the Next.js frontend, and **JWT bearer
validation** (issuer + audience + JWKS) on the .NET backend. It reuses each
project's existing `<NAME>_OIDC_CLIENT_ID` / `<NAME>_OIDC_CLIENT_SECRET` /
`<NAME>_APP_SECRET` slots, adds the realm `OIDC_ISSUER_URL`, and derives the
redirect / post-logout URLs from the subdomain — adding **no new service and no
host ports** (it uses the Keycloak already running at `auth.<BASE_DOMAIN>`). It is
**optional and never forced** — a public marketing site (`company-site`) omits it.

The only thing the module **cannot** do from code is the **one-time, operator-run
Keycloak console step**: create a realm and a **confidential client per project**
(with the project's redirect URIs), then paste the client id/secret into `.env`.
That is documented in
[`templates/modules/auth-sso/SETUP.md`](../templates/modules/auth-sso/SETUP.md) and
**deferred to the final manual session**. Until it is done, the project builds and
runs normally with the auth endpoints reporting `503` (auth OFF). See the
[module README](../templates/modules/auth-sso/README.md) for the full flow.

> **Note on public hosting.** Generated projects are reachable on the Pi /
> internal network through Caddy out of the box. To expose one to the **public
> internet** over HTTPS — with no inbound ports opened on the Pi — see
> [Public hosting (Cloudflare Tunnel)](#public-hosting-cloudflare-tunnel) below
> and the full walkthrough in
> [`docs/cloudflare-tunnel.md`](cloudflare-tunnel.md).

---

## Quality gate

A **lightweight, on-demand quality gate** for the projects you generate. It runs
static analysis / linting, the relevant compiler + analyzer checks, and a
dependency vulnerability scan against one project, prints **pass/fail per check**,
and **exits non-zero on any failure** — so you can drop it into a deploy step as
an actual gate. Full detail: [`services/quality/README.md`](../services/quality/README.md).

> **Optional and Pi-aware.** It is **script-driven** (no always-on service), so it
> consumes **zero RAM unless you run it**. SonarQube and similar heavyweight,
> ARM-unfriendly analyzers are **deliberately not used**; the gate uses only
> lightweight tooling that ships with the stacks the platform targets. Checks run
> **strictly sequentially** in throwaway, pinned ARM64 SDK containers (the same
> `mcr.microsoft.com/dotnet/sdk:10.0` and `node:22-alpine` images the templates
> build from), so at most one container is alive at a time — gentle on the Pi 5.

### Run it against a project

```bash
./scripts/quality.sh <name>          # e.g. ./scripts/quality.sh happy-teeth
```

It detects the stack from the project's files (`*.csproj` ⇒ .NET, `package.json`
⇒ Next.js; a `fullstack` project runs both) and runs:

| Stack | Checks |
| ----- | ------ |
| **.NET** | `dotnet restore`; `dotnet build` with **warnings-as-errors + Roslyn analyzers**; `dotnet format --verify-no-changes`; `dotnet list package --vulnerable` |
| **Next.js / JS** | `npm ci`; **ESLint** (the project's `npm run lint`, else a pinned `next lint` with `eslint@8.57.1` + `eslint-config-next@15.5.18`); `npm audit` |

Your project is mounted **read-only** and copied into a disposable in-container
dir, so a run never leaves `node_modules/`, `obj/`, `bin/` or a lockfile behind.
Two optional knobs (`QUALITY_DOTNET_WARN_AS_ERROR`, `QUALITY_NPM_AUDIT_LEVEL`)
live in the **QUALITY GATE** section of `.env.example`. The gate needs Docker but
**no** .NET/Node install on the host, and **no** platform service to be running.

---

## Package cache

An **optional** local cache for **npm** (Verdaccio) and **NuGet** (BaGetter) that
transparently **mirrors + caches the public registries**, so repeated installs on
the Pi are faster and survive a flaky link. Full detail:
[`services/cache/README.md`](../services/cache/README.md).

> **Optional and Pi-aware.** Both registries sit behind the Compose **`cache`
> profile**, so they **never auto-start** and consume **zero RAM until you run
> `./scripts/cache.sh up`**. When the cache is down, projects fall back to the
> public registries. Images are pinned + ARM64; no host ports (only Verdaccio's
> UI is exposed, and only through Caddy).

| Service | Image (pinned) | Reached as | UI |
| ------- | -------------- | ---------- | -- |
| `verdaccio`   | `verdaccio/verdaccio:6.7.1` | `http://verdaccio:4873/` (internal) | `https://cache.<BASE_DOMAIN>` |
| `nuget-cache` | `bagetter/bagetter:1.6.5`   | `http://nuget-cache:8080/v3/index.json` (internal) | — (internal only) |

We ship **BaGetter** (the maintained, multi-arch fork of BaGet) rather than a
plain shared folder because it **mirrors nuget.org read-through** — projects keep
restoring *any* public package with no manual copying — while staying far lighter
than JVM-heavy servers (Nexus/Artifactory), which are ARM-unfriendly. A shared
folder source is documented as the zero-container alternative in the cache README.

### Run the cache

```bash
./scripts/cache.sh up        # start verdaccio + nuget-cache (profile: cache)
./scripts/cache.sh status
./scripts/cache.sh logs      # cache hits/misses
./scripts/cache.sh down      # remove containers; cached packages are KEPT
```

### How a project opts in

Opting in is **optional and never forced**. Either:

1. **Generator flag** — `./scripts/new-project.sh ... --cache` writes the opt-in
   file(s) into the new project: a frontend **`.npmrc`** (→ `verdaccio:4873`) and
   a backend **`nuget.config`** (a single `pi-cache` source → `nuget-cache:8080`).
   They are copied from [`services/cache/optin/`](../services/cache/optin) and
   placed at the project root (`nextjs-app`/`dotnet-api`) or under `frontend/` +
   `backend/` (`fullstack`). This is **non-breaking** — without `--cache`, nothing
   is added and base behavior is unchanged.
2. **Env / CLI per install** (graceful auto-fallback, no committed file):
   ```bash
   npm_config_registry=http://verdaccio:4873/ npm ci
   dotnet restore --source http://nuget-cache:8080/v3/index.json
   ```
   Unset ⇒ the public registries are used automatically.

> **⚠ Build-network note.** A committed `.npmrc`/`nuget.config` is a **hard
> opt-in**: the cache must be **up** *and* reachable on the **`internal`**
> network where the install runs. `docker compose build` uses an isolated build
> network by default, so to use the cache at *image-build* time, set the build
> network (Compose `build.network: ${INTERNAL_NETWORK_NAME:-pi_internal}` — the
> base stack must be up). Otherwise prefer the env/CLI method (graceful fallback)
> and let the cache speed up host-side and `compose run` installs. To stop using
> the cache, delete the `.npmrc`/`nuget.config` (or regenerate without `--cache`).

---

## Web analytics

A **self-hosted, privacy-first** way to see — for the sites you **own** (your own
portfolio and the client sites you host) — **who visits, which pages they view,
where they came from, and what they click**. It deliberately replaces **Google
Analytics**: nothing about your visitors is ever sent to a third party. It needs
**no external account**.

It comes in two halves: a **platform service** (the analytics engine) and a
composable **module** (the per-site tracking snippet).

### The service vs the module

- **Service** — [`services/analytics/analytics.compose.yml`](../services/analytics/analytics.compose.yml)
  runs **[Umami](https://umami.is)** (a lightweight, ARM64, privacy-first engine —
  chosen over Plausible because it is lighter and PostgreSQL-based, fitting this
  stack) plus its **own dedicated, isolated PostgreSQL** (service `umami-db`, its
  own volume — the same isolation as Keycloak's private DB). Both sit behind the
  Compose **profile `analytics`**, so they **never auto-start** and use **zero RAM**
  until you bring them up. The dashboard is reached **only via Caddy** at
  `analytics.<BASE_DOMAIN>` — **no host ports**, DB internal-only.
- **Module** — [`templates/modules/web-analytics/`](../templates/modules/web-analytics/README.md)
  injects the tracking snippet into a generated project's Next.js frontend. It is
  **env-gated** (renders nothing until configured), **needs no database and no
  credentials**, and cooperates with the i18n and auth layouts (it adds a root
  `template.jsx` that nests inside the layout rather than replacing it). It is
  **optional** and composed by the `company-site` and `ecommerce` presets; add it to
  any project with `--modules web-analytics`.

### Why Umami (privacy-first, self-hosted)

Umami sets **no cookies** and collects **no personal data** by default
(GDPR/PECR-friendly — usually no cookie banner needed), serves both the dashboard
and the `/script.js` tracker from the one container, and is a single Node app + one
Postgres DB (far lighter on a Pi than Plausible's Elixir + ClickHouse + Postgres).

### Start it

```bash
# 1. Set the two secrets in .env (generate strong random values):
#      ANALYTICS_DB_PASSWORD=$(openssl rand -hex 24)
#      ANALYTICS_APP_SECRET=$(openssl rand -hex 32)
# 2. Bring it up (profile-gated; never auto-starts), and make sure Caddy is up:
./scripts/analytics.sh up        # up | down | logs | status
./scripts/start-proxy.sh
# 3. Open the dashboard and change the default admin password immediately:
#      https://analytics.<BASE_DOMAIN>     (first-boot login: admin / umami)
```

`down` removes only the containers — the `umami_db_data` volume (all collected
analytics) is kept. (Optionally add the analytics DB to backups via
`BACKUP_EXTRA_TARGETS=postgres:umami-db:5432:umami:umami:ANALYTICS_DB_PASSWORD`.)

### Enable analytics for the portfolio / a client site

The operator's **own portfolio** is the primary first use:

1. In the Umami dashboard, **add a website** for the site and copy its **website id**.
2. In `.env`, set the tracker URL (shared by all sites) and this site's id:
   ```ini
   ANALYTICS_SCRIPT_URL=https://analytics.<BASE_DOMAIN>/script.js
   ANALYTICS_SITE_ID=<the-website-id>
   ```
   For **many** sites, keep `ANALYTICS_SCRIPT_URL` shared and give each project its
   own `<PREFIX>ANALYTICS_SITE_ID` (e.g. `ACME_ANALYTICS_SITE_ID`) — the module's
   compose fragment prefers it and falls back to the shared value.
3. (Re)start the project: `./scripts/project.sh up <name>`. Page views and custom
   events now appear in the dashboard. To track clicks/conversions, add a
   `data-umami-event="…"` attribute or call the shipped `trackEvent()` helper — see
   the [module README](../templates/modules/web-analytics/README.md).

> **No external credentials.** Everything above is self-hosted on the Pi. The only
> "credentials" are the `.env` secrets you generate for the analytics service itself.

---

## SEO & site quality

A **scheduled / on-demand auditor** for the sites you **own** — your portfolio and
the client sites you host — plus a **free, deterministic recommendations engine**
with an **optional, off-by-default AI** enrichment. It scores each site
(performance, SEO, accessibility, best-practices), stores results over time so you
can see **trends**, and turns them into a prioritised, actionable report. It is the
sibling of the [Quality gate](#quality-gate): that audits a project's **code**, this
audits a running site's **SEO / quality**.

> **Default path needs no external credentials.** Auditing and the rule-based
> recommendations are entirely free and self-hosted. The only optional credential is
> an AI key you supply to *enrich* the report — off by default (see below).

### Honest about the Pi: a light probe by default, Lighthouse on opt-in

A real Lighthouse run drives **headless Chromium**, which is **heavy on a Pi 5**
(hundreds of MB of RAM + real CPU per run) — an always-on browser is exactly the
cost this platform avoids. So:

- **Default engine — a lightweight Node probe (no browser).** It fetches each page
  over HTTP, runs deterministic on-page checks (title, meta description, headings,
  `lang`/`dir`, canonical, viewport, Open Graph, alt text, robots.txt & sitemap.xml
  reachability, JSON-LD), measures basic timing/size metrics, and computes
  Lighthouse-**style** category scores from documented rules. Free, no credentials,
  tiny footprint.
- **Opt-in engine — real Lighthouse (headless Chromium).** For a true Lighthouse
  Performance score + **measured Core Web Vitals** (LCP/CLS/TBT), add
  `--engine lighthouse`. A separate, heavier image — never the default; run it
  sparingly, one site at a time.

Neither is always-on: both sit behind the Compose **profile `seo`** and run as
**one-shot** containers (no host ports, internal-only) launched by
[`scripts/seo.sh`](../scripts/seo.sh) and scheduled with the existing host-cron
pattern via [`scripts/seo-install-cron.sh`](../scripts/seo-install-cron.sh) — **not**
an always-on browser. Results are stored as **append-only JSON Lines keyed by
service name** under `data/seo/` (a file-backed, server-less store — no always-on DB
for a few audit rows a day), the same Pi-aware reasoning the quality gate and
backup/health-monitor use. Full detail: [`services/seo/README.md`](../services/seo/README.md).

### Run an audit

```bash
# 1) List the sites you OWN (portfolio + hosted clients):
mkdir -p data/seo && cp services/seo/sites.example.conf data/seo/sites.conf
$EDITOR data/seo/sites.conf            # add "<name> <url>" lines

# 2) Audit (default = the free, light probe engine):
./scripts/seo.sh audit happy-teeth     # one site
./scripts/seo.sh audit all             # every listed site, one at a time

# 3) See results, trends and the report:
./scripts/seo.sh list                  # latest scores per site
./scripts/seo.sh trend happy-teeth     # first → latest per category
./scripts/seo.sh recommend happy-teeth # re-print recommendations (no new probe)

# 4) (Optional) the heavy, real Lighthouse engine for true Core Web Vitals:
./scripts/seo.sh audit my-site --engine lighthouse

# 5) Schedule a weekly audit (host cron, one-shot container):
./scripts/seo-install-cron.sh          # --dry-run to preview, --remove to undo
```

### Free rule-based recommendations — and the OPTIONAL AI enrichment

The engine **always** produces a deterministic, prioritised report (critical → low)
from fixed rules — **no API, no AI, no network**. On top of that, an **optional** AI
enrichment uses the platform's **swappable-provider** pattern (the same one
`whatsapp-integration` and `local-payments` use): it is **fully coded but inert**
until **both** env vars are set in `.env`:

```ini
AI_PROVIDER=openai          # openai | anthropic | compatible | none (blank = OFF)
AI_API_KEY=<your-own-key>   # REQUIRED to enable — usage is billed on YOUR account
# AI_MODEL=  AI_BASE_URL=    # optional overrides (model id / compatible endpoint)
```

| `AI_PROVIDER` | `AI_API_KEY` | Result |
| ------------- | ------------ | ------ |
| blank / `none` | — | **Rule-based only** (the default). No key, no network, no cost. |
| set | **blank** | Stays rule-based (it never half-enables). |
| set | **set** | AI **enriches** the rule-based report (it only *adds*, never replaces). |

**It is OFF by default**, **no key is committed or required now**, and when you do
supply one, **usage is billed on your own account**. After an audit, an optional
notifier can push a one-line summary to your existing alert channel (Uptime Kuma
push, or `SEO_NOTIFY_CMD` — e.g. the Telegram bot bridge).

### On the generated-site side: the `seo-toolkit` module

The auditor checks sites; the
[`seo-toolkit`](../templates/modules/seo-toolkit/README.md) **module** gives a
generated site the on-page SEO defaults the auditor looks for — per-page **meta tags
+ Open Graph/Twitter**, a **bilingual `sitemap.xml`** and **`robots.txt`**, and
**JSON-LD** structured-data scaffolding — **cooperating with `i18n-bilingual`**
(per-locale URLs + `hreflang`) and `auth-sso` (its `robots.txt` keeps `/account` out
of the index). It is **strictly additive** (no layout/page/template collisions),
needs **no database and no external credentials**, and is composed by the
`company-site`, `ecommerce` and `real-estate` presets (add it anywhere with
`--modules seo-toolkit`). Submit the generated `https://<site>/sitemap.xml` in Google
Search Console / Bing Webmaster Tools, then re-audit to confirm the score recovers.

> **Default path needs no external credentials** — both halves (auditing + on-page
> defaults) are free and self-hosted. Only the optional AI enrichment of the
> *recommendations* needs a key you supply, and it stays off until you set one.

### Multi-specialist AI panel (the "technical team") — OPT-IN

`./scripts/seo.sh audit <site> --panel` (or `prospects.sh analyze <id> --panel`, or
`SEO_AI_PANEL=1`) adds a **multi-specialist** layer on top of the audit: a focused AI
analyst per category (performance, security, SEO, accessibility, best-practices) **plus a
sales-angle analyst**, then a **lead-analyst synthesis** that enforces exactly **one #1
priority** + a deduped unified action plan and cross-cutting risks. It renders as an
additive **"Specialist panel"** section in the report and can surface the #1 priority in
the operator alert. It is **operator-only** and sends nothing.

It is **hallucination-hardened**: finding references are computed by *us* from the audit's
real findings (a model can't invent an id), any claim that doesn't map to a real
finding/metric is shown as a **"general suggestion" (not a detected issue)**, and any
**invented number is stripped** — only figures traceable to `audit.metrics/checks/scores`
survive.

> **Cost (be honest with yourself):** the panel is **off by default** because it is **more
> AI calls**. A normal audit makes **at most one** AI call; with `--panel` it makes, *per
> audited site*, **one call per specialist (6) + one synthesis call ≈ up to 7 additional
> calls**, billed on **your** key. With **no** AI key it is fully **inert** — every
> specialist and the synthesis fall back to deterministic templates with **zero network
> calls**, so the panel still renders, just rule-based. See `SEO_AI_PANEL` in `.env.example`.

---

## Client prospect organizer

A **self-hosted, operator-owned CRM-lite** for a **manual** client-acquisition
workflow. **You** find prospects yourself and **enter** them; the tool **organizes**
the pipeline (status, notes, follow-up reminders) and **analyzes** a prospect's
**own public website** by **reusing the [SEO engine](#seo--site-quality)**; then
**you contact them yourself**. It is the organizing sibling of the auditor: that
audits sites **you own**; this organizes **prospects you found** and analyzes
**their own public site** as a conversation starter. Growth layer #4.

> **⚠ The boundary is architectural — not a toggle.** This tool is for
> **organization + your own research**, never harvesting or mass outreach, and the
> code is built that way:
>
> - **No platform scraping.** There is **no** Google Maps / LinkedIn / search
>   integration anywhere — **not even an optional stub**. You enter prospects by
>   hand.
> - **No automated or bulk outreach. No auto-send.** The image carries **no
>   outreach transport at all** (no SMTP / WhatsApp / bulk sender) — the test suite
>   asserts the absence of any send code path. It *cannot* send.
> - **Public-site analysis only.** It fetches **exactly the one public URL you
>   entered**, once, like any visitor — never crawling a third-party platform.
> - **Follow-up reminders go to YOU**, on your own channel — never to a prospect.
> - **No scraper-fed import.** If you ever bring in a list, it is a **manual CSV you
>   compiled yourself** (and none ships here — single manual entry is preferred).

### The manual workflow

```bash
# 1) Add a prospect YOU found (the only way data gets in — manual entry):
./scripts/prospects.sh add "Acme Dental Clinic" --url https://acme.example --note "met at the expo"

# 2) Work the pipeline (new → contacted → in-talks → won/lost; transitions validated):
./scripts/prospects.sh list
./scripts/prospects.sh update acme-dental-clinic --status contacted
./scripts/prospects.sh note   acme-dental-clinic "Left a message with reception"
./scripts/prospects.sh update acme-dental-clinic --followup 2026-06-01   # set a reminder

# 3) Analyze the prospect's OWN public site (reuses the SEO engine) and save a report:
./scripts/prospects.sh analyze acme-dental-clinic

# 4) See what's due today — a reminder to YOU (--notify pushes to YOUR own channel):
./scripts/prospects.sh followups
./scripts/prospects.sh followups --notify

# 5) Draft a message to COPY, personalize and send yourself (this NEVER sends):
./scripts/prospects.sh template audit-offer acme-dental-clinic   # or: intro | followup
```

The pipeline is a **single small JSON document** under `data/prospects/`
(git-ignored, on the SSD) — file-backed and server-less, the same Pi-aware reasoning
the [SEO store](#seo--site-quality) uses (no always-on database for a handful of
records). The organizer runs as a **one-shot** container behind the Compose
**profile `prospects`** (no host ports, internal-only) and exits — **zero RAM when
idle**.

### Public-site analysis — reuses the SEO engine (no parallel analyzer)

`analyze` contains **no analyzer of its own**. It imports the **existing** SEO
engine — the **same** no-browser [probe](#seo--site-quality), the **same**
deterministic rules, the **same** report renderer, and the **same optional,
off-by-default AI enrichment** (inert unless `AI_PROVIDER` + `AI_API_KEY` are set;
usage billed on your own key). The result is a clean, shareable Markdown report —
performance / SEO / accessibility / best-practice gaps — that **you review, edit and
send yourself** as a professional *"here's what I noticed."* The default engine is
the free probe; **Lighthouse is opt-in** (`--engine lighthouse`, ingesting a JSON
you produced via `scripts/seo.sh`), exactly like the auditor.

### Follow-up reminders to the operator, and copy-yourself templates

`followups` lists the prospects **due** for a follow-up (open prospects whose
reminder date has arrived; won/lost are excluded). With `--notify` — or the daily
[`scripts/prospects-install-cron.sh`](../scripts/prospects-install-cron.sh) job — it
pushes a one-line summary to **your own** channel (`PROSPECTS_NOTIFY_CMD`, e.g. the
[Telegram bot](#telegram-management-bot) bridge to message **yourself**, or an Uptime
Kuma push). This is a nudge **to you** to reach out manually — **never** an outbound
message to the prospect.

`template` renders a **draft** message (`intro` / `followup` / `audit-offer`, in
English or Arabic) that you **copy, personalize, and send yourself** through your own
channel. It keeps obvious `[PLACEHOLDERS]` and prints a "DRAFT — this tool does not
send" banner; the `audit-offer` draft references your saved analysis. **The tool
never sends it** and has no auto-send/bulk path.

> **Default path needs no external credentials.** Organizing and the public-site
> analysis are free and self-hosted; only the optional AI enrichment (the shared SEO
> seam) needs a key you supply, and it stays off until you set one. Full detail:
> [`services/prospects/README.md`](../services/prospects/README.md). Unit-tested
> offline (`./tests/prospects/run.sh`) — including a test that **asserts there is no
> send or scrape code path**.

---

## Security hardening

This platform is built to expose **only** ports 80/443 (Caddy) to the network,
keep databases internal-only, and read every credential from the git-ignored
`.env`. Two areas need deliberate operator action to lock the box down: the
**host firewall** and **secrets**. The relevant scripts live in
[`scripts/`](../scripts) and are designed to be **safe** — none of them can lock
you out of SSH or silently overwrite your `.env`.

### Firewall (UFW) — staged for you, enabled by you

[`scripts/harden-firewall.sh`](../scripts/harden-firewall.sh) configures
[UFW](https://help.ubuntu.com/community/UFW) for a **default-deny-incoming**
posture that allows only what the platform needs:

| Port      | Proto   | Why                                                     |
| --------- | ------- | ------------------------------------------------------- |
| SSH (22)  | tcp     | Remote administration (override with `--ssh-port N` / `$SSH_PORT`). |
| 80        | tcp     | Caddy: HTTP→HTTPS redirect and ACME HTTP-01 challenge.  |
| 443       | tcp     | Caddy: HTTPS (TLS).                                      |
| 443       | udp     | Caddy: HTTP/3 (the proxy binds `443/udp`).              |

Everything else inbound is denied; outbound stays open.

```bash
sudo ./scripts/harden-firewall.sh                 # default SSH port 22
sudo ./scripts/harden-firewall.sh --ssh-port 2222 # custom SSH port
```

> **It does not enable the firewall.** By design, the script only *stages* the
> rules, prints them (`ufw show added`), and then stops. **You** turn the
> firewall on yourself, deliberately, after reviewing the rules:
>
> ```bash
> sudo ufw enable
> ```
>
> This split exists so a default-deny firewall is never switched on over SSH
> without a human confirming the SSH rule first.

#### ⚠ SSH-lockout warning and recovery

Turning on a default-deny firewall **over SSH** can permanently cut your session
if the SSH port isn't actually allowed. The script mitigates this by
**auto-detecting the port of your current SSH session** (from `$SSH_CONNECTION`)
and always allowing it in addition to `--ssh-port`. Still, before you run
`sudo ufw enable`:

1. Confirm an SSH rule for **your** port appears in the printed preview.
2. Keep your current SSH session **open** as a safety net.
3. Run `sudo ufw enable`, then open a **second, new** SSH connection to confirm
   you can still get in **before** closing the first.

**If you do get locked out**, it cannot be fixed over SSH — you need **local /
console access** to the Pi (monitor + keyboard, or the serial console). Log in
locally and run either:

```bash
sudo ufw disable                    # turn the firewall back off, or
sudo ufw allow <your-ssh-port>/tcp  # add the missing SSH rule
```

To discard the staged rules entirely and start over: `sudo ufw reset`.

#### ⚠ Docker can bypass UFW

Docker manipulates `iptables` directly, **below** UFW. As a result, any
container that **publishes a port to `0.0.0.0`** (e.g. `ports: ["8080:80"]`)
can be reachable from the network **even when UFW claims to block it** — UFW's
rules simply don't see that traffic. This is a well-known Docker/UFW interaction,
not a bug in this platform.

**Mitigation — and why this platform is already safe:** the only container that
publishes host ports is **Caddy** (80/443), exactly the ports the firewall
allows. Every other service (databases, admin UIs, Keycloak, Portainer, ...)
publishes **no host ports** and is reached over the internal Docker networks or
through Caddy. To keep it that way:

- **Do not** add `ports:` that bind to `0.0.0.0` for new services — front them
  with Caddy on the `proxy` network instead.
- If you ever genuinely must publish a container port for host-only use, bind it
  to loopback explicitly: `ports: ["127.0.0.1:8080:80"]`.
- The optional "Bootstrap access" blocks in `management.compose.yml` are
  commented out for this reason — only uncomment them briefly for emergencies,
  then re-comment.
- For strict control of container-published ports under UFW, see the community
  [`ufw-docker`](https://github.com/chaifeng/ufw-docker) approach. It is an
  **operator decision** and is intentionally **not** applied automatically here,
  because it rewrites Docker's networking rules.

### Secrets — generate strong values, then audit

All credentials live only in the git-ignored `.env` (never in a committed file).
Two scripts manage them; neither ever prints a secret value.

**1. Generate** — [`scripts/generate-secrets.sh`](../scripts/generate-secrets.sh)
writes a populated `.env` from `.env.example`, filling every **secret** field
with a strong random value (40 alphanumeric chars from `openssl rand`). Non-secret
values (usernames, db names, `BASE_DOMAIN`, network names, ...) are left blank
for you to fill in.

```bash
./scripts/generate-secrets.sh            # create .env (refuses if one exists)
./scripts/generate-secrets.sh --force    # regenerate (backs up the old .env first)
./scripts/generate-secrets.sh --length 48
```

The fields it fills: `POSTGRES_PASSWORD`, `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`,
`MONGO_INITDB_ROOT_PASSWORD`, `REDIS_PASSWORD`, `PGADMIN_DEFAULT_PASSWORD`,
`ME_CONFIG_BASICAUTH_PASSWORD`, `KC_DB_PASSWORD`, `KC_BOOTSTRAP_ADMIN_PASSWORD`.

> It **never overwrites an existing `.env`** unless you pass `--force`, and even
> then it first copies the old file to a timestamped, git-ignored
> `.env.bak.<timestamp>`. Because `--force` regenerates from the template,
> non-secret values reset to blank — copy them back from the backup if needed.
> Secrets are **never** echoed; the script only reports which keys it filled.

**2. Audit** — [`scripts/check-secrets.sh`](../scripts/check-secrets.sh) inspects
the current `.env` **without revealing any value** and reports:

- secrets that are **empty** (a warning — fine only if you don't use that
  service yet),
- secrets that are **set but weak/short** or a common default (e.g. `password`),
  and
- a **hard check** that `REDIS_PASSWORD` is non-empty — an empty one leaves Redis
  running **unauthenticated** on the internal network.

```bash
./scripts/check-secrets.sh                  # exits non-zero on critical problems
./scripts/check-secrets.sh --min-length 24  # stricter length recommendation
```

It exits **non-zero** if any *critical* problem is found (empty `REDIS_PASSWORD`,
a value below the hard minimum length, or a known weak/default value), so it can
gate a deploy.

### Pre-exposure security checklist

Run through this **before** pointing a public domain at the Pi:

- [ ] `./scripts/check-secrets.sh` passes (exit 0) — no empty/weak secrets.
- [ ] `.env` is git-ignored and was **never** committed (it is, by default).
- [ ] `sudo ./scripts/harden-firewall.sh` run, rules reviewed, **then**
      `sudo ufw enable` — verified via a second SSH session.
- [ ] No service publishes host ports except Caddy (80/443); check with
      `docker ps` that only Caddy shows `0.0.0.0:80/443`.
- [ ] Databases remain `internal`-only (no `ports:`), reached by service name.
- [ ] `BASE_DOMAIN` set to your real domain and `ACME_EMAIL` set, so Caddy issues
      **public** Let's Encrypt certificates (HTTP→HTTPS enforced automatically).
- [ ] Keycloak `KC_HOSTNAME` set to the full public URL for correct token/redirect
      issuance.
- [ ] First-login admin accounts created and the **bootstrap** admins (Keycloak,
      Portainer) secured/rotated.
- [ ] SSH itself hardened (key-only auth, root login disabled) — outside this
      repo's scope but strongly recommended.

---

## Public hosting (Cloudflare Tunnel)

A project generated by [`new-project.sh`](../scripts/new-project.sh) can be made
reachable from the **public internet** over HTTPS **without opening any inbound
port on the Pi** — the default-deny firewall and the 80/443-only design stay
exactly as they are. A [**Cloudflare Tunnel**](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
(`cloudflared`) running on the Pi dials **outbound** to Cloudflare and forwards
traffic to the **existing Caddy** reverse proxy over `localhost`. Caddy still
issues a **real public Let's Encrypt certificate** via its own ACME — there is no
manually-installed Cloudflare certificate and no second proxy.

```
Browser ──https──▶ Cloudflare edge ──tunnel (Pi dials OUT)──▶ cloudflared ──▶ Caddy ──▶ project
                                                              (no inbound ports on the Pi)
```

- **TLS is only Caddy's built-in ACME.** Caddy answers Let's Encrypt's HTTP-01
  challenge on `:80` *through the tunnel* and serves the site on `:443` with the
  cert it obtains — end-to-end TLS (Cloudflare "Full (strict)").
- **Nothing is per-project on the Pi.** Installing `cloudflared`, the tunnel, and
  the Caddy `http_port` global block are **one-time** setup. Publishing each new
  project only adds a **DNS record** and the project's **Caddy site block**.
- **Automatic Let's Encrypt.** The generated site block already carries
  `tls {$CADDY_TLS:internal}`; it switches to public Let's Encrypt the moment
  `BASE_DOMAIN` + `ACME_EMAIL` are set in the Pi's `.env`. No manual cert step.

### Walkthrough

The full step-by-step (generate → copy to Pi → install/configure `cloudflared` →
link the tunnel to Caddy → DNS record → automatic Let's Encrypt → start & test),
including the **one-time** Pi setup, lives in
[**`docs/cloudflare-tunnel.md`**](cloudflare-tunnel.md). It suggests the
`ecommerce` preset as a good test case (it composes both feature modules,
`i18n-bilingual` + `content-admin`), but any project with a web-facing component
can be exposed the same way.

### Helper script

Once the one-time setup exists, [`scripts/deploy-to-tunnel.sh`](../scripts/deploy-to-tunnel.sh)
automates the per-project steps from your dev machine over SSH — it copies the
project to the Pi, verifies the tunnel, ensures the Caddy `http_port` + site
blocks, adds the Cloudflare DNS route, sets `BASE_DOMAIN`/`ACME_EMAIL` in the
Pi's `.env` (backing it up first), reloads Caddy and starts the project:

```bash
# Set the Pi connection in the script's CONFIG block (or via env vars), then:
./scripts/deploy-to-tunnel.sh --name shop --subdomain shop --email you@example.com
```

It never opens inbound ports, never touches the databases/auth/base compose, and
never prints secret values. Run [`./scripts/check-secrets.sh`](../scripts/check-secrets.sh)
and the [pre-exposure checklist](#pre-exposure-security-checklist) first.

---

## Backup & restore

The platform backs itself up with a system whose defining feature is **tested
restore**. A backup you have never restored is not a backup — it is a hope — so
an automated **restore drill** runs on a schedule into **disposable throwaway
containers** and fails loudly if a backup cannot actually be brought back. Every
artifact is **encrypted at rest** (no plaintext dumps ever leave the engine),
the tools are **ARM64 and version-pinned**, and the job connects to each
database **by service name on the internal network** using the credentials
already in `.env` — no host ports, no disturbance to the running services.

```
            ┌── pg_dumpall ──┐                       ┌─ disposable postgres ─┐
 postgres ──┤                ├─ gzip ─ age ─ *.age ──┤                       │
 mysql ─────┤  (by service   │   (encrypted at rest) │  weekly DRILL: decrypt│
 mongo ─────┤   name, only   │        │              │  → restore → integrity│
 redis ─────┤   if running)  │        ▼              │  check → throw away   │
 keycloak-db┘                │   data/backups/       └───────────────────────┘
 + config + extra targets    │   daily/ weekly/         NEVER touches live data
```

### What's backed up

| Source | Tool | Notes |
|--------|------|-------|
| PostgreSQL (`postgres`) | `pg_dumpall` | Whole instance (roles + all DBs). |
| Keycloak DB (`keycloak-db`) | `pg_dumpall` | The isolated identity store. |
| MySQL (`mysql`) | `mysqldump` | Configured app DB, consistent snapshot. |
| MongoDB (`mongo`) | `mongodump --archive --gzip` | Configured DB (or all). |
| Redis (`redis`) | `redis-cli --rdb` | Network RDB snapshot. |
| Extra project DBs | per engine | From `BACKUP_EXTRA_TARGETS` (e.g. content-admin's `<project>-cms-db`). |
| Critical config | `tar` | Compose files, Caddyfile, `.env`, ... (`data/`, `secrets/` excluded). |

Only the engines that are **currently running** are touched — the database layer
is on-demand, so a stopped engine is **skipped**, not an error. Each run lands in
`data/backups/daily/<timestamp>/` with a `manifest.txt` (per-artifact status +
SHA-256), and a status file is written to `data/backups/status/`.

### Encryption model & safe key storage

Artifacts are encrypted with [`age`](https://github.com/FiloSottile/age). The
backup encrypts to a **public recipient**; restoring needs the matching
**private identity**. Generate the key once:

```bash
./scripts/backup.sh init-key      # writes secrets/backup/age-identity.key (mode 600, git-ignored)
```

> ⚠ **Keep a copy of `secrets/backup/age-identity.key` somewhere safe and
> offline.** It is the *only* thing that can decrypt your backups. If the Pi's
> SSD dies and you have not kept a copy, every backup is unrecoverable.

If neither a key (`BACKUP_AGE_KEY_FILE`) nor explicit recipients
(`BACKUP_AGE_RECIPIENTS`) are configured, the job **aborts** rather than writing
plaintext. [`check-secrets.sh`](../scripts/check-secrets.sh) flags a missing
backup key as **critical**. Keys are never committed (`secrets/` is git-ignored).

### Tested restore — the weekly drill (never touches live data)

```bash
./scripts/backup-verify.sh        # or: ./scripts/backup.sh verify
```

For each database in the latest backup, the drill spins up a **brand-new,
single-use** engine container (pinned to the same version the platform runs) on
a **dedicated throwaway network that is not connected to `internal`**, restores
the decrypted dump into it, runs a basic integrity check (databases/schemas
recreated, a known query, key counts), then **destroys the container and its
volume** — even on error. It reports **PASS/FAIL per database** and exits
non-zero if any fails, so a silently-rotting backup is caught. The live
databases are never reachable from the drill, let alone written to.

### The guarded real restore (overwrites live data — operator only)

```bash
# Always preview first:
./scripts/restore.sh --engine postgres --dry-run
# Then, deliberately:
./scripts/restore.sh --engine postgres --confirm
```

[`restore.sh`](../scripts/restore.sh) is the **only** path that writes to live
databases, and it is deliberately hard to trigger: it does nothing without
`--confirm`, on a terminal it also makes you **type `RESTORE`**, and
non-interactively it additionally requires `--yes`. It **never runs
automatically**. `--engine` selects `postgres | keycloak-db | mysql | mongo |
redis | config`; Postgres/MySQL/Mongo restore over the internal network, while
Redis and config are decrypted to a staging dir with the exact offline steps
printed (Redis runs with AOF, so it must be restored offline). Recommended
recovery order: stop the apps → restore into a clean target → verify → restart.

### Retention

Rotation keeps `BACKUP_RETENTION_DAILY` daily snapshots (default 7) and
`BACKUP_RETENTION_WEEKLY` weekly ones (default 4); the first successful run each
ISO week is promoted to `weekly/`, and older snapshots beyond the limits are
pruned after each successful backup.

### Scheduling & monitoring

```bash
./scripts/backup-install-cron.sh             # daily backup 02:30 + weekly drill Sun 03:30
./scripts/backup-install-cron.sh --dry-run   # preview the crontab block
./scripts/backup.sh status                   # last backup + last drill result (warns if stale)
```

Scheduling is **host cron** (one transparent mechanism; the drill must create
disposable containers, and a one-shot backup avoids an always-on container
eating Pi RAM). Success/failure is observable three ways: the on-disk
`status/last-backup.json` + `status/last-verify.json`, the appended logs, and —
if you set `BACKUP_UPTIME_KUMA_PUSH_URL` / `BACKUP_VERIFY_UPTIME_KUMA_PUSH_URL`
to an Uptime Kuma **Push** monitor — an up/down heartbeat, so a missed or failed
run is noticed.

### Optional offsite (deferred)

The core works **entirely locally with no external account**. For real disaster
recovery you will also want the encrypted backups copied **offsite**. Because
artifacts are already encrypted, the destination never sees plaintext — point
your own sync (e.g. `rclone` to S3/B2) at `data/backups/` using the
`BACKUP_OFFSITE_*` templates in `.env.example`. This, like the other external
credentials (WhatsApp, payments, Keycloak realm), is **deferred to the final
manual session**.

---

## Resource monitoring

Uptime Kuma tells you whether a service **answers**. It cannot see the
slow-burn risks that come from running 24/7 on a constrained Pi — the ones that
build up over weeks and only bite long after launch:

- **Thermal** — under sustained load (a .NET build, Keycloak warming up) the Pi
  5's SoC heats up; past ~80 °C it **throttles**, and a weak PSU/cable shows up
  as **under-voltage**. Both quietly cost performance.
- **Disk** — logs, backups and Docker layers **slowly fill the SSD**. A full
  disk is how a healthy-looking platform falls over with no warning.
- **Memory** — a **leak** or a service sitting **right against its limit** drives
  the Pi into swap (thrashing the SSD) or the OOM killer.

[`scripts/health-monitor.sh`](../scripts/health-monitor.sh) is a **read-only**
probe of exactly these three. It prints a PASS / WARN / FAIL report and a final
verdict; with `--status-dir` it also writes a status file + log and, on
WARN/FAIL, fires a swappable notifier. It **never** starts/stops a container,
changes config, or prints a secret.

```bash
./scripts/health-monitor.sh                 # full report to your terminal
./scripts/health-monitor.sh --quiet         # just the verdict (+ any WARN/FAIL)
./scripts/health-monitor.sh --no-docker     # skip the per-container section
```

### Where it fits — three checkpoints, three jobs

| Stage | Tool | Question it answers |
| ----- | ---- | ------------------- |
| **Pre-launch** | [`preflight.sh`](../scripts/preflight.sh) + [`mem-budget.sh`](../scripts/mem-budget.sh) | *Is the host ready, and does the profile fit in RAM?* (before anything starts) |
| **Bring-up** | [`startup.sh`](../scripts/startup.sh) | *Did each layer come up healthy?* (one-time, verified) |
| **Ongoing** | **`health-monitor.sh`** | *Is the running Pi still healthy — thermally, on disk, in memory?* (forever after) |

### What it watches, and the verdict

A check is **PASS** (fine), **WARN** (attention recommended), **FAIL** (over a
hard threshold) or **SKIP** (not measurable here — e.g. no Pi sensor, or Docker
down). The final verdict is the **worst** of all checks; SKIP never counts as a
problem. Exit code: `0` for PASS/WARN/SKIP, `1` for FAIL.

| Check | Source (graceful if absent) | Default WARN / FAIL |
| ----- | --------------------------- | ------------------- |
| CPU temperature | `vcgencmd measure_temp`, else `/sys/class/thermal` | **70 / 80 °C** |
| Throttling flags | `vcgencmd get_throttled` (active bit ⇒ FAIL, historical-only ⇒ WARN) | — |
| Root / SSD usage | `df -P /` | **80 / 90 %** |
| Docker data dir | `df -P` of `DOCKER_DATA_DIR` (only if on a different filesystem) | **80 / 90 %** |
| RAM used | `free` (used = total − available) | **85 / 95 %** |
| Swap used | `free` (no swap configured ⇒ PASS) | **50 / 80 %** |
| Per-container memory | `docker stats --no-stream` (% of each container's **own** limit) | **85 / 95 %** |

When the disk is under pressure it also names the **biggest consumer**
(backups vs Docker), so you know what to prune.

### Tuning the thresholds

Every threshold has a flag (`--temp-warn`, `--disk-fail`, `--mem-warn`,
`--swap-fail`, `--ctr-warn`, …) **and** an `.env` key (`HEALTH_TEMP_WARN`,
`HEALTH_DISK_FAIL`, …) — see the **HOST HEALTH MONITORING** section of
`.env.example`. Precedence is **flag › environment › `.env` › built-in
default**, so the bare command works out of the box, and the scheduled run (which
does not source `.env`) still picks up your `.env` tuning — `health-monitor.sh`
reads those specific keys from `.env` directly (without executing it, and never
printing them).

### Scheduled run + swappable alerting

Scheduling reuses the **same host-cron approach as the backup system** (one
transparent mechanism; a one-shot probe, no always-on agent eating Pi RAM):

```bash
./scripts/health-monitor-install-cron.sh             # every 15 min -> ./data/health
./scripts/health-monitor-install-cron.sh --dry-run   # preview the crontab block
./scripts/health-monitor-install-cron.sh --remove    # uninstall
```

Each run writes `data/health/last-health.json` (machine-readable verdict +
numbers) and appends a line to `data/health/health.log` (kept bounded — it can
never itself fill the SSD). On **WARN/FAIL** it fires a **swappable notifier**,
exactly the pattern used by the n8n `platform-health-alert` workflow:

1. **Default, zero-config:** writes `data/health/last-alert.txt` (and the status
   file) for the operator — or Uptime Kuma — to watch. No secret, no setup.
2. **Uptime Kuma push (optional):** set `HEALTH_UPTIME_KUMA_PUSH_URL` to a Kuma
   **Push** monitor URL — FAIL ⇒ `down`, WARN/PASS ⇒ `up`. That monitor then
   shows up on the existing Uptime Kuma card on the **Homepage dashboard**, so
   host health lands next to service health with **no new dashboard component**.
3. **Your own channel (optional):** set `HEALTH_NOTIFY_CMD` to your script; it is
   called as `<cmd> <VERDICT>` with the alert body on stdin. Keep every
   token/webhook **inside that script** (git-ignored) — never in committed files.

PASS and SKIP are **silent** (no alert noise). The alert file is cleared once the
host is healthy again.

### Log hygiene — keep logs from filling the SSD

Docker's default `json-file` log driver has **no size cap**, so a chatty or
crash-looping container can quietly consume the SSD over weeks. The single,
central, surgical fix (no compose file is rewritten) is a Docker-daemon default —
see [`infrastructure/docker-daemon.json.example`](../infrastructure/docker-daemon.json.example):

```bash
sudo cp infrastructure/docker-daemon.json.example /etc/docker/daemon.json
# (merge by hand if /etc/docker/daemon.json already exists)
sudo systemctl restart docker        # containers pick up the new log config on recreate
```

That bounds **every** container at `max-size 10m × max-file 3` (≈30 MB each),
rotating the rest away. To override one service instead, add a `logging:` block
to its compose service (this is the per-service escape hatch — use sparingly):

```yaml
    logging:
      driver: json-file
      options:
        max-size: "5m"
        max-file: "5"
```

### Intentionally lightweight (no heavy metrics stack)

This is a deliberate design choice: a **read-only shell probe + host cron + a
status file**, reusing patterns the platform already has. There is **no Grafana,
no Prometheus, no node-exporter, no always-on agent** — that telemetry stack
would itself consume the very CPU, RAM and disk a Pi can least spare, defeating
the purpose. If you ever outgrow this, point the Uptime Kuma push (or
`HEALTH_NOTIFY_CMD`) at an external collector you run **off** the Pi.

### Tested

The parsing and the threshold/notify decision logic live in
[`scripts/lib/health-monitor-lib.sh`](../scripts/lib/health-monitor-lib.sh)
behind mockable seams, and are unit-tested **without a Pi, Docker, or root**:

```bash
./tests/health-monitor/run.sh    # exits non-zero on any failure
```

It covers the threshold bands (temp/disk/memory/swap edges), sensor/`df`/`free`/
`docker stats` parsing (including a `df` source with spaces and `GiB`/float
sizes), the throttle-flag decode (active ⇒ FAIL, historical ⇒ WARN), the
"near its limit" container detection, verdict folding (SKIP never a false FAIL),
the notifier decision (alerts only on WARN/FAIL), and end-to-end scenarios
(healthy ⇒ PASS/silent, full disk ⇒ WARN/notify, throttling ⇒ FAIL/notify). See
[`tests/health-monitor/README.md`](../tests/health-monitor/README.md).

---

## Control panel

The self-hosted **web control panel** ([`services/control-api/`](../services/control-api/))
— one Next.js service that now serves **both** a browser UI **and** its API on the
same origin. It does two jobs:

1. **Monitor / control** the platform (status, health, projects, checks, and the
   bring-up/teardown/restart actions), and
2. act as a secure, service-aware **config / integration manager** so you can
   connect API keys (Telegram token, AI key, WhatsApp, payments, …) from the web
   instead of hand-editing `.env` on the Pi.

It is ARM64, version-pinned, on `internal` + `proxy`, publishes **no host ports**,
runs `no-new-privileges` with a 256M cap and `restart: unless-stopped`, and is
reachable **only** through Caddy at `https://api.${BASE_DOMAIN}`. Start it with
[`./scripts/control-api.sh up`](../scripts/control-api.sh).

> **Part #1** built the secure API (below). **Part #2** ported the designed
> frontend into this same service as the panel UI and wired it to that API — see
> **[Panel UI](#panel-ui-control-panel-part-2)**. **Part #3** wired the New-Project
> wizard end to end so the panel can **securely create projects** — see
> **[Project creation](#project-creation-control-panel-part-3)**. **Part #4** wired
> the **Monitoring** + **Growth** views to LIVE data via new **read-only** endpoints
> — see **[Live Monitoring & Growth](#live-monitoring--growth-control-panel-part-4)**.
> **Every panel section is now live.** The API's security model is unchanged (the
> same whitelist + operator-for-writes + audited bridge pattern; the new feeds are
> read-only and add NO write/exec capability).

### Panel UI (control-panel part #2)

The panel is a calm, Linear-style, **bilingual Arabic-RTL-primary / English**
dashboard (light + dark), served by this same service at `https://api.${BASE_DOMAIN}/`.
It was ported from the design prototype into the App Router (`app/` + `components/`);
the prototype's CDN-React/Babel harness and artboard scaffolding were dropped and
replaced by the real build. Charts use **recharts** and animations **framer-motion**
(pinned, ARM64-safe); fonts are **self-hosted** via `next/font` (no runtime CDN).
The design tokens stay the single source of truth (`components/theme.js`); RTL is
structural (logical CSS).

**Browser login (OIDC, BFF).** The panel signs in with **Authorization Code +
PKCE** against the same Keycloak realm, reusing the platform's `auth-sso`
conventions (`openid-client` + `jose`). The flow runs **server-side** under
`/api/auth/{login,callback,session,logout}`: tokens are sealed into an **httpOnly,
encrypted session cookie** — **the browser never sees a token** (nothing in
`localStorage`). Same-origin API calls are authorized by that cookie; the existing
API also still accepts `Authorization: Bearer` for programmatic clients (the access
token from the cookie is verified by the *identical* JWKS/issuer/audience/role path
— an extra transport, not a weaker check). The cookie is `SameSite=Lax`, so it is
not sent on cross-site POSTs (CSRF-safe for the action endpoints). Unauthenticated
visitors get a sign-in gate; if the panel's Keycloak client isn't configured yet
the gate explains the deferred setup. The logged-in identity + a **Sign out** are
always shown.

**Wired LIVE vs PENDING** (explicit by design):

| View | Status |
|---|---|
| **Overview** | **Live** — polls `GET /api/status` + `/api/system-health` (every `NEXT_PUBLIC_CONTROL_PANEL_POLL_MS`, default 5s) + `/api/projects`; start/stop core + restart an unhealthy service via the confirm dialog → `POST /api/actions/*`. |
| **Projects** | **Live** — list from `/api/projects`; per-project **start/stop** via `POST /api/actions/project-{up,down}` through the confirm→pending→result dialog. |
| **Settings · Integrations** | **Live** — `GET /api/integrations` (set/empty only, **secret values never returned/rendered** — the KeyRow input is write-only); edit → `PUT /api/integrations/{key}`; then a restart drawer offers `POST /api/actions/restart-service`. |
| **New-project wizard** | **Live** — review → confirm dialog (names exactly what will be created) → `POST /api/projects` → pending → success (the new project + a deploy stepper) or a clear error (validation / **409 conflict** / permission); the list then refreshes. Creation is **operator-only** and runs through the secure generation bridge (whitelist + double validation + audited + **no `--force`**). Generation creates the project **files only** — bringing it up is the separate **Start** (`project-up`) action. See [Project creation](#project-creation-control-panel-part-3). |
| **Monitoring** (time-series, per-service memory, alerts, backup) | **Live** — `GET /api/monitoring` (CPU/RAM/disk series from the health monitor's own log + latest verdict + a current per-container snapshot), `GET /api/monitoring/alerts`, `GET /api/backup-status`. The range selector slices the last N rows of REAL history (rows are ~15 min apart). See [Live Monitoring & Growth](#live-monitoring--growth-control-panel-part-4). |
| **Growth** (prospects, SEO, analytics, templates) | **Live** — `GET /api/growth/{prospects,seo,analytics}`. Prospects board + embedded analysis (read/organize only); SEO scores-over-time + rule-based recs; privacy-first analytics summary (or a clean "not configured" state). The **Message drafts** stay STATIC, **copy-paste only** (never auto-sent). |

Read-only views degrade gracefully (loading / error / empty); `401/403` surface as
re-login / not-authorized rather than crashing. Because `status`/`system-health`/
`projects` return the host tool's **text** report today (no JSON mode), a small
pure adapter (`lib/adapt.js`) parses it into the structured shape the UI expects
and keeps the raw text available — and transparently passes through structured
JSON if those endpoints ever emit it (no UI change needed).

### Security model (Keycloak JWT + operator role)

- **Every endpoint except `GET /api/health` requires a valid Keycloak JWT.** The
  API verifies the token's signature against the realm **JWKS**, plus the expected
  **issuer** and **audience** (`jose`/`createRemoteJWKSet`). A missing/invalid
  token → **401**.
- **All state-changing AND config-writing endpoints additionally require the
  operator role** (allowlist philosophy). A valid token without the role → **403**.
  The role is read from `realm_access.roles` and `resource_access.<client>.roles`;
  its name is configurable (`CONTROL_API_OPERATOR_ROLE`, default `operator`).
- **Fails closed.** If the OIDC trust anchors are not configured the API refuses to
  authenticate (it never silently allows access).
- Responses use a clean envelope — `{ "status": "ok", "data": … }` or
  `{ "status": "error", "error": "…" }` — with correct codes (200/400/401/403/429/
  500). **No stack traces or secrets are ever returned.** State-changing and
  config-writing endpoints are **throttled** (per-identity fixed window).

### Monitoring / control endpoints (thin — they orchestrate existing tools)

These never reimplement anything: each maps to a fixed [`bot-exec.sh`](../scripts/bot-exec.sh)
action (which in turn drives `scripts/pi` / `scripts/project.sh`).

| Method & path | Role | Maps to (bot-exec) |
|---|---|---|
| `GET /api/health` | public | — (liveness only) |
| `GET /api/status` | any token | `status` → `scripts/pi status` |
| `GET /api/system-health` | any token | `health` → `scripts/pi health` |
| `GET /api/projects` | any token | `projects` (read-only listing) |
| `GET /api/checks` | any token | `check` → `scripts/pi check` |
| `POST /api/actions/up` · `/down` | operator | `up` / `down` (profile, default `core`) |
| `POST /api/actions/project-up` · `/project-down` | operator | `project_up` / `project_down` (project name) |
| `POST /api/actions/restart-service` | operator | `restart` (allowlisted service) |
| `POST /api/projects` (`?dryRun=1`) | operator | `create-project` → `scripts/new-project.sh` (via the **sibling** bridge `bot-exec-generate.sh`) |
| `GET /api/monitoring` | any token | `monitor_metrics` → `scripts/panel-read.sh` (read-only) |
| `GET /api/monitoring/alerts` | any token | `monitor_alerts` → `scripts/panel-read.sh` (read-only) |
| `GET /api/backup-status` | any token | `backup_status` → `scripts/panel-read.sh` (read-only) |
| `GET /api/growth/seo` | any token | `seo_audits` → `scripts/panel-read.sh` (read-only) |
| `GET /api/growth/prospects` | any token | `prospects_list` → `scripts/panel-read.sh` (read-only) |
| `GET /api/growth/analytics` | any token | — (server-side read of Umami over the internal network; no bridge) |

The **constrained execution path / security boundary**: the API is **never given
the Docker socket**. It reaches the host **only** over SSH using a dedicated key
pinned to the bot-exec **forced command** — the *same* path the Telegram bot uses:

```
command="bash /PATH/scripts/bot-exec.sh --from-ssh",no-pty,… <bridge-pubkey>
```

The API sends only a validated `"<action> <arg>"`; `bot-exec` re-validates it
against its fixed action set (defence in depth). The action ARGV is always built
as an **array** (e.g. `["restart","analytics"]`) and spawned with `execFile` — no
shell ever interprets a value, and there is no other way for the API to run a host
command.

### Project creation (control-panel part #3)

`POST /api/projects` securely scaffolds a new project from the wizard payload —
mirroring the bot-exec security model **exactly**, scoped to one new action:

- **Whitelisted action.** Creation maps to a single fixed action, `create-project`,
  handled by a **tightly-scoped sibling bridge**,
  [`scripts/bot-exec-generate.sh`](../scripts/bot-exec-generate.sh), that follows
  the identical pattern as `bot-exec.sh`. It accepts ONLY a fixed flag set and maps
  it to [`scripts/new-project.sh`](../scripts/new-project.sh) as an **ARGV array**
  (`execFile`/argv-join, never a shell string, never `eval`).
- **Double validation (defence in depth).** Every field is validated against
  allowlists / strict patterns at **both** layers — the API
  ([`lib/generate-core.js`](../services/control-api/lib/generate-core.js)) and the
  bridge ([`scripts/lib/bot-lib.sh`](../scripts/lib/bot-lib.sh)):
  **name** (`^[a-z][a-z0-9-]{0,38}[a-z0-9]$` — never a path separator or shell
  metacharacter), **preset** XOR **base shape** (`dotnet-api|nextjs-app|fullstack`)
  with every **module** in the implemented allowlist, **db** (`postgres|mysql|mongo|none`),
  **subdomain** (DNS label) and **locale** (`ar|en`). Anything else is **rejected**,
  never sanitized-and-run. The control-api/bot test suites **cross-check** the JS
  and bash allowlists so they cannot drift.
- **Operator-only + throttled + audited.** The endpoint requires the operator role
  (a valid token without it → **403**), is rate-limited per identity, and every
  creation is appended to the audit log (identity + name + result; never a value).
- **Never `--force` — no silent overwrite.** The API path never offers `--force`.
  If the name already exists the bridge exits with a dedicated **conflict** code
  and the API returns **409** with the existing folder untouched (`new-project.sh`
  also refuses without `--force`: defence in depth).
- **No Docker socket, separate key.** Like the control bridge, the API never gets
  the Docker socket; it reaches the host over SSH using a **dedicated forced-command
  key** pinned to `bot-exec-generate.sh --from-ssh` (one key = one forced command,
  so generation gets its **own** key).
- **Codes:** `200` (created) · `400` (validation) · `403` (not operator) ·
  `409` (name exists) · `502` (host error). `?dryRun=1` validates and returns what
  *would* be created without writing.

**Generate ≠ deploy.** Creation writes the project FILES only. Bringing the new
project up (deploying) remains the SEPARATE `project-up` action (the **Start**
button / `POST /api/actions/project-up`) — the two are never conflated.

### Live Monitoring & Growth (control-panel part #4)

The Monitoring and Growth views now render **live** data instead of sample
fixtures. The platform's own producers already write status/log/store files; this
part exposes them through **read-only** endpoints — adding **no** new write/exec
capability.

- **One read-only door:** [`scripts/panel-read.sh`](../scripts/panel-read.sh)
  READS the producers' files (and a read-only `docker stats --no-stream` snapshot
  for current per-container memory) and prints JSON. It only `cat`/`tail`s — no
  write, no start/stop, no config change, no `eval`. A missing source degrades to
  `null`/`[]` (a clean empty state, never a 500). It is reached **only** through
  the audited bot-exec bridge, which whitelists the feeds as **READ-ONLY** actions
  (`monitor_metrics`, `monitor_alerts`, `backup_status`, `seo_audits`,
  `prospects_list`) — same `execFile`/ARGV path, no Docker socket, every call
  audited. The bridge-core JS and `bot-lib.sh` agree the feeds are read-only (the
  test suite cross-checks both layers so they cannot drift).
- **Pure adapters** ([`lib/adapt.js`](../services/control-api/lib/adapt.js)) map
  each producer's JSON into the exact UI shapes (tolerant + JSON-pass-through),
  e.g. the health monitor's `health.log` rows → the CPU/RAM/disk **time-series**
  (the range selector slices the last N rows of REAL history — rows are ~15 min
  apart), `last-health.json` → the **verdict**, the SEO JSONL → **scores over
  time + rule-based recommendations**, the prospects store → the **board + each
  prospect's embedded analysis**.
- **Monitoring** (`GET /api/monitoring` · `/api/monitoring/alerts` ·
  `GET /api/backup-status`): live charts (the current point still overlays
  `system-health`), a current per-container memory snapshot (no per-service
  history is persisted, so it is shown as usage bars, not a fake trend), severity-
  tagged alerts derived from the monitor's own log, and the last backup +
  restore-drill from the backup service's status files.
- **Growth** (`GET /api/growth/{prospects,seo,analytics}`): the prospects board +
  analysis drawer, the SEO site-quality view, and the analytics view. **Prospects
  are READ/ORGANIZE only in the panel** — no scraping, no outreach send, no
  editing here; adding/updating a prospect would be a SEPARATE operator-only,
  audited write (a possible later part). The **Message drafts** stay STATIC and
  **copy-paste only** — never auto-sent. (Add/manage prospects + run an analysis
  on the host with [`scripts/prospects.sh`](../scripts/prospects.sh).)
- **Analytics summary (Umami):** fetched **server-side** from the self-hosted
  Umami over the **internal** network (`http://umami:3000`). The credentials live
  ONLY in the API server's env (`CONTROL_API_ANALYTICS_UMAMI_URL` / `…_USERNAME`
  / `…_PASSWORD` / `…_WEBSITE_ID`) and are **NEVER returned to the browser** — the
  client receives only the cookie-less aggregates (visitors, top pages, referrers,
  countries). This is **lighter + safer** than scraping Umami's database and reuses
  its own privacy-first aggregates. When the env is unset the endpoint returns a
  clean `{ configured: false }` so the panel shows a **"not configured"** state
  (with a one-time-setup hint), not an error; when set but unreachable it shows an
  error state. *Deferred setup:* run the `analytics` profile and set those four
  env keys (a read-capable Umami user + the website UUID).
- **Reads need only a valid token** (matching the existing GET policy — no operator
  role) and are lightly throttled with a separate, generous bucket
  (`CONTROL_API_READ_RATE_MAX`, default 300/min) so polling stays smooth.

### Config / integration manager (allowlist-only)

- The editable surface is a **service-aware allowlist** in
  [`services/control-api/config-registry.json`](../services/control-api/config-registry.json):
  each entry declares a human **label**, the owning **service**, whether it is a
  **secret**, a basic value **shape** check, and which services must be
  **restarted** after a change. The API can read/write **only** keys in this
  manifest — never an arbitrary `.env` variable (so e.g. `REDIS_PASSWORD` or
  `KC_DB_PASSWORD`, which are *not* listed, can never be touched here).
- `GET /api/integrations` — returns, per integration, each key's label and whether
  it is **SET** or **EMPTY**; for **secrets it returns a masked indicator only —
  never the value**. Requires a valid token.
- `PUT /api/integrations/{key}` — **operator-only.** Validates the key is in the
  allowlist and the value matches its expected shape (and rejects any value
  containing a newline — a `.env` line-injection guard). It then writes `.env`
  **safely, reusing the secrets-script conventions**: it **backs up** `.env` first
  (timestamped, like `generate-secrets.sh`), writes **atomically** (temp file +
  rename) and **preserves comments/structure** (the line is replaced in place).
  The **value is never logged**; the response says which services now need a
  restart. Empty templates for every managed key live in `.env.example` (the
  `TELEGRAM BOT`, `SEO & SITE QUALITY` (AI), `WHATSAPP BUSINESS`, `LOCAL PAYMENTS`
  and `ANALYTICS` sections).
- After a change, `POST /api/actions/restart-service` recreates just the affected
  service (operator-only, allowlisted names: `automation analytics auth dashboard
  cache control-api`) via the bot-exec `restart` action, which runs that service's
  own `down`+`up` helper on the host (a recreate, so the new value is picked up).

### Audit logging

Every state-changing **and** config-writing request is appended (JSON line) to
`data/control-api/audit.log` with **identity + action + target + result** — and,
by construction, **never a value**: the audit record has no field a secret could
land in, and a config write records only the *key name*. Rejected attempts (bad
key, bad shape, missing role) are logged too.

### Deferred one-time setup

1. **Keycloak client (API trust + browser login).** Create a client for the
   control panel, then set `CONTROL_API_OIDC_ISSUER`, `CONTROL_API_OIDC_AUDIENCE`
   (and optionally `CONTROL_API_OIDC_JWKS_URI`) in `.env`, and assign the
   `operator` role to your user. Until issuer + audience are set the API fails
   closed. For the **panel UI login** also set the browser-OIDC slots in the same
   `.env` section: `CONTROL_API_OIDC_CLIENT_ID` (usually = audience),
   `CONTROL_API_OIDC_REDIRECT_URI` = `https://api.${BASE_DOMAIN}/api/auth/callback`,
   `CONTROL_API_OIDC_APP_BASE_URL` = `https://api.${BASE_DOMAIN}`, and a random
   `CONTROL_API_SESSION_SECRET` (e.g. `openssl rand -hex 32`) to encrypt the
   session cookie. Use a **public** client (PKCE, no secret) or set
   `CONTROL_API_OIDC_CLIENT_SECRET`. Until client id + redirect + session secret
   are set, login is off and the panel shows a "not configured yet" gate.
2. **SSH bridge key(s).** Generate a dedicated key at
   `./secrets/control-api/bridge_key`, add its public half to the host
   `authorized_keys` pinned to the bot-exec forced command (above), and set
   `CONTROL_API_BRIDGE_SSH_HOST` / `…_USER` in `.env`. For **project creation**
   add a SECOND dedicated key at `./secrets/control-api/generate_bridge_key`
   (one SSH key = one forced command), pinned to the generation forced command:
   `command="bash /PATH/scripts/bot-exec-generate.sh --from-ssh",no-pty,… <pubkey>`.
   Host/user/port default to the control bridge's; override the
   `CONTROL_API_GENERATE_BRIDGE_*` slots only if they differ.
3. **Container user.** The API runs as `CONTROL_API_UID:CONTROL_API_GID`
   (default `1000:1000`); it must match the owner of `.env` so the config manager
   can write it.

Then: `./scripts/control-api.sh up` (ensure Caddy is up). Liveness:
`https://api.${BASE_DOMAIN}/api/health`.

### Tests (offline — no Docker / network / Keycloak)

[`tests/control-api/run.sh`](../tests/control-api/run.sh) drives a pure-logic
Node harness plus static bash checks proving: the **authz matrix** (no token →
401, non-operator → 403 on writes/actions, operator → allowed), the **registry
allowlist** (rejects any key not in the manifest), that `GET /api/integrations`
**never returns secret values** (set/empty/masked only), the **safe `.env`
writer** (structure preserved + backup + value never leaked, via a mocked fs
seam), the **restart whitelist**, and that **no endpoint builds an arbitrary shell
command** (argv arrays + `execFile` only). For **project creation** it proves the
`create-project` **field validators** (accept valid; reject bad slug / unknown
preset / unknown module / bad subdomain / path-traversal & metacharacter names),
that the API maps to an **ARGV array** (never a shell string) and **never** emits
`--force`, the **operator-role gate**, the **409 conflict** on an existing name,
and that `bot-exec-generate.sh` refuses anything but `create-project` (dry-run,
incl. an SSH-injection attempt). It also cross-checks the JS restart **and**
create-project allowlists against `bot-lib`'s (so they cannot drift). For the
**part #4 read-only feeds** it proves each feed is **read-only in BOTH layers**
(bridge-core + `bot-lib`) and reaches **no** state-changing runner, that
`panel-read.sh` emits **valid JSON** for every subcommand and degrades to
`null`/`[]` on missing data, and — crucially — that running every subcommand
leaves the data fixtures **byte-identical** (proven read-only) with **no mutating
command** in its code; plus the Umami summary's **configured-vs-not** logic and
that the analytics **token is never returned**. See
[`tests/control-api/README.md`](../tests/control-api/README.md).

The **panel UI** logic has its own offline suite,
[`tests/control-ui/run.sh`](../tests/control-ui/run.sh) (no Docker / browser):
a Node harness proving the **API-client request shaping** (method/path/body +
bearer attached), the **auth-guard decision** (no session → login), that a
**secret value is never displayable** (from a fixture, even a malicious one), the
**action confirm→pending→success/error state machine**, the **wizard payload
builder** + the **create submit** (`buildCreateConfirm` → confirm → pending →
success/error, naming the exact target), and the **live-data adapters** — incl.
the **part #4** Monitoring/Growth adapters (host JSON → exact UI shapes: metrics
series, alerts, backup, SEO scores+recs, prospects board, analytics summary +
not-configured/error states) and the read-only feed **request shaping**; plus
static checks that the prototype scaffolding was dropped, fonts are self-hosted
(no CDN), the session endpoint never returns tokens, the wizard now calls
`client.createProject` (no copy-paste dead-end), Monitoring/Growth dropped the
`SAMPLE_*` fixtures + "live source pending" badge (now fetch live), the Message
drafts stay copy-paste only (no auto-send), and the new deps are pinned.
A real `next build` of the merged app is the final gate. See
[`tests/control-ui/README.md`](../tests/control-ui/README.md).

---

## Conventions & hard rules

These apply to every service added in future phases:

- **ARM64 only.** Every image must support `linux/arm64` (Raspberry Pi 5).
- **Pin versions.** Always use an explicit image tag — **never** `latest`.
- **No secrets in files.** Reference environment variables / secret files only;
  never hard-code passwords. `.env`, `secrets/` and `data/` are git-ignored.
- **One service, one folder** under `services/`, each with its own compose file
  that attaches to the shared `internal` / `proxy` networks.

---

## Next step

The edge (reverse proxy), the on-demand database layer, a centralized
**identity provider** (Keycloak), perimeter **security hardening**, and now a
**three-layer template system** (base + modules + presets) for scaffolding new
client projects are all in place. With
[`scripts/new-project.sh`](../scripts/new-project.sh) a new project is generated
into `services/` from a sector preset or a base shape + modules — Dockerized for
ARM64, wired to a database by service name, fronted by Caddy, bilingual-ready, and
ready to be guarded by Keycloak — all with no host ports and no secrets in
committed files. Sector feature modules layer on top as they are built.

**Public hosting is now in place too.** A generated project can be published to
the internet through a **Cloudflare Tunnel** — no inbound ports opened on the Pi —
with a real public Let's Encrypt certificate issued by Caddy's own ACME
(`BASE_DOMAIN` + `ACME_EMAIL`). See
[Public hosting (Cloudflare Tunnel)](#public-hosting-cloudflare-tunnel), the
walkthrough in [`docs/cloudflare-tunnel.md`](cloudflare-tunnel.md), and the
[`deploy-to-tunnel.sh`](../scripts/deploy-to-tunnel.sh) helper.

**SSO is now a module too.** Wiring a project behind **Keycloak** is the optional
`auth-sso` module — real OIDC (Authorization Code + PKCE on the frontend, JWT
validation on the backend), composed by the `clinic` and `real-estate` presets and
available to any project via `--modules auth-sso`. It adds no new service; the only
remaining work is the **one-time, operator-run Keycloak step** (create a realm + a
client per project), documented in
[`templates/modules/auth-sso/SETUP.md`](../templates/modules/auth-sso/SETUP.md) and
**deferred to the final manual session**.

**Messaging and payments are now modules too.** `whatsapp-integration` (WhatsApp
notifications/templates) and `local-payments` (mada / Apple Pay / card checkout) are
both `implemented`, built on a **swappable-provider** design: each runs a **mock /
sandbox provider by default** (so the flow builds, runs and is testable now with no
external account) and a fully-coded **real** provider (the WhatsApp Cloud API;
Moyasar) that stays **inert until credentials are set**. They are composed by the
`clinic` / `ecommerce` / `real-estate` presets and available anywhere via
`--modules`. See [`whatsapp-integration/SETUP.md`](../templates/modules/whatsapp-integration/SETUP.md)
and [`local-payments/SETUP.md`](../templates/modules/local-payments/SETUP.md).

**Backups are now in place too.** A platform-level **encrypted backup system**
with **tested restore** dumps every running database (plus the Keycloak DB, extra
project DBs and config), encrypts each artifact with `age`, and proves
recoverability with a **weekly drill into disposable throwaway containers** that
never touches live data. A separate, **operator-confirmed** `restore.sh` handles
real recovery. See [Backup & restore](#backup--restore);
generate the key once with `./scripts/backup.sh init-key` and schedule it with
`./scripts/backup-install-cron.sh`.

**Automation is now in place too.** **n8n** (`./scripts/automation.sh up`) is the
platform's central workflow engine — deployed securely like the others (its own
isolated database, no host ports, proxy-fronted at `automation.<BASE_DOMAIN>`,
reverse-proxy/edge mode, `N8N_ENCRYPTION_KEY` from `.env` and flagged critical by
`check-secrets.sh`). It ships **one** internal-operations workflow,
[platform-health-alert](#the-bundled-workflow--platform-health-alert), with a
swappable notifier. **Client-acquisition / scraping / cold-outreach workflows are
intentionally deferred** pending legal/ToS review. See [Automation (n8n)](#automation-n8n).

**A unified dashboard now ties it together.** **Homepage**
(`./scripts/dashboard.sh up`) is a single landing page at `home.<BASE_DOMAIN>`
that links to, and shows the health of, every platform service — deployed like the
others (no host ports, proxy-fronted, no privileged Docker socket, secret-free
committed config). See [Dashboard (Homepage)](#dashboard-homepage).

**The template base was security-patched.** Next.js is now pinned to
**`next@15.5.18`** (was `15.1.0`), remediating **CVE-2025-66478**; the fix lives in
the base, so it propagates to every project generated from now on (verified with a
clean `fullstack` + `nextjs-app` build of the full module set).

**Two developer-productivity additions round out the build, both optional and
Pi-aware.** A lightweight [**Quality gate**](#quality-gate)
(`./scripts/quality.sh <name>`) lints, analyzes and vuln-scans a generated project
and exits non-zero on failure — script-driven, no SonarQube, checks run
sequentially in throwaway pinned ARM64 SDK containers, so it costs nothing when
idle. A local [**Package cache**](#package-cache) (`./scripts/cache.sh up`) runs
**Verdaccio** (npm) and **BaGetter** (NuGet) behind the `cache` profile to mirror +
cache the public registries; a project opts in via `./scripts/new-project.sh
... --cache` (or per-install env), never forced, with public-registry fallback.

This completes the **code-side build of the platform**. All six feature modules,
the encrypted-backup/tested-restore system, the n8n automation engine, the unified
Homepage dashboard, and now the quality gate + package cache are implemented; the
Next.js base CVE is remediated. **No app-level code remains to build.** What is left
are the **operator-run, one-time steps deferred to the final manual session** —
flipping each swappable-provider module from mock to live (create a Meta / WhatsApp
Business account for `whatsapp-integration`; open a Moyasar merchant account for
`local-payments`; set the env keys), creating the Keycloak realm/client for
SSO-enabled projects, and wiring the **optional offsite copy** of the encrypted
backups (`BACKUP_OFFSITE_*`, e.g. `rclone` to S3/B2) — plus optional Cloudflare
**WAF / Access** policies in front of sensitive subdomains.

**Pre-launch hardening has begun.** The **first step of that final manual
session is the [Preflight check](#preflight-check)** —
`./scripts/preflight.sh`, a **read-only** readiness check run on the Pi before any
`up`, that catches the likely first-run failures early (Docker/daemon/Compose,
arm64, free disk + RAM, SSD vs SD card, `.env` completeness + secret strength,
compose parse + collisions, image-tag existence + arm64, network/volume plan). It
scopes to what you intend to run, exits non-zero on any FAIL, and is itself
unit-tested offline (`./tests/preflight/run.sh`).

**Pre-launch hardening #2 — resource safety — is now in place too.** Every
long-running service already declared a memory limit; this part audits and
documents them as a [source-of-truth table](#memory-limit-source-of-truth)
(no compose changes were needed — nothing was missing), adds explicit
[**boot profiles**](#boot-profiles) (`core`, `dev`, `auth`, `automation`, and the
illustrative `full-ish`) as a small documented map in
[`infrastructure/boot-profiles.conf`](../infrastructure/boot-profiles.conf), and
ships [`scripts/mem-budget.sh`](../scripts/mem-budget.sh) — a **read-only** tool
that sums a profile's limits and checks them against the Pi's RAM (minus a sane
OS reserve) with a PASS/WARN/FAIL verdict, so the operator never accidentally
exceeds memory. Run it **between preflight and `up`**, and see
[Resource safety](#resource-safety) for the 8 GB-vs-16 GB guidance. It is
unit-tested offline (`./tests/mem-budget/run.sh`). More pre-launch hardening parts
will build on top of these.

**Pre-launch is now complete — there is one authoritative first-run guide.** The
[**FIRST-RUN RUNBOOK**](RUNBOOK.md) is the final pre-launch integration step: it
weaves every tool and section above — hardware/OS prep, secrets (with the offline
keys), preflight + memory budget, the staged core bring-up, log rotation, the
firewall, backups + a restore drill, ongoing health, the first generated project —
**and** all the deferred one-time external steps (Keycloak realm/client, WhatsApp +
Moyasar go-lives, Cloudflare Tunnel, offsite backups) into one ordered, copy-paste
sequence, with a verify and an "if it fails" pointer at every stage and a
consolidated [deferred-steps checklist](RUNBOOK.md#deferred-manual-steps-checklist)
+ [troubleshooting appendix](RUNBOOK.md#troubleshooting-appendix). A thin,
test-covered [`scripts/pi doctor`](../scripts/pi) reads the current state and prints
the next command in that sequence. **Begin the guided first-run manual session
there: [`docs/RUNBOOK.md`](RUNBOOK.md).**

**Growth layer #1 — a Telegram management bot — is now in place too.** A
**lightweight, operator-only** bot lets you monitor and control the platform from
Telegram: receive alerts, query status (`/status` `/health` `/check` `/projects`),
and trigger a **safe, whitelisted** set of actions (`/up` `/down` `/project_up`
`/project_down`). It is built **on top of** the existing tools — an n8n
**workflow** ([`telegram-management-bot.json`](../automation/workflows/telegram-management-bot.json))
plus a thin, audited bridge ([`scripts/bot-exec.sh`](../scripts/bot-exec.sh)) that
orchestrates `scripts/pi` / `status.sh` / `project.sh` — so there is **no new
always-on container and no paid AI**. It is locked to an **allowlist** of Telegram
ids (fail closed), accepts whitelisted actions only, validates every argument,
logs state changes, and shares one channel with the
[health alerts](#alerts-and-control-share-one-channel). The only remaining work is
the **one-time, operator-run BotFather step** (create the bot, get the token, set
`TELEGRAM_ALLOWED_IDS`, wire the n8n credential + SSH key), **deferred to the manual
session** and documented in [Telegram management bot](#telegram-management-bot). It
is unit-tested offline (`./tests/bot/run.sh`).

**Growth layer #2 — privacy-first web analytics — is now in place too.** **Umami**
(`./scripts/analytics.sh up`, profile-gated) is a self-hosted analytics engine — no
Google Analytics, no third-party tracker, no external account — and the
[`web-analytics`](#web-analytics) module injects its env-gated tracking snippet into
a generated site (opt-in via `.env`). See [Web analytics](#web-analytics).

**Growth layer #3 — SEO & site quality — is now in place too.** An **on-demand
auditor** for the sites you own (`./scripts/seo.sh`, profile-gated, one-shot — no
always-on browser) scores each site (performance, SEO, accessibility,
best-practices), stores results over time, and produces **free, deterministic,
rule-based recommendations** — with an **optional AI enrichment** that is fully coded
but **inert until `AI_PROVIDER` + `AI_API_KEY` are set** (off by default; usage
billed on your own key). Honest about the Pi, it defaults to a **lightweight Node
probe (no Chromium)** and keeps real **Lighthouse** as a heavier opt-in
(`--engine lighthouse`). The generated-site companion is the
[`seo-toolkit`](#seo--site-quality) module — on-page SEO defaults (meta + Open Graph,
a **bilingual** `sitemap.xml` & `robots.txt`, JSON-LD) that cooperate with `i18n`,
`auth-sso` and `web-analytics` — composed by the `company-site`, `ecommerce` and
`real-estate` presets. **The default path needs no external credentials.** It is
unit-tested offline (`./tests/seo/run.sh`). See [SEO & site quality](#seo--site-quality).

**Growth layer #4 — a client prospect organizer — is now in place too.** A
**self-hosted, operator-owned CRM-lite** (`./scripts/prospects.sh`, profile-gated,
one-shot) for a **manual** client-acquisition workflow: **you** find prospects
yourself and enter them, the tool **organizes** the pipeline (status transitions,
notes, follow-up reminders) and **analyzes a prospect's own public website** by
**reusing the SEO engine** (no parallel analyzer; same inert-until-keyed AI seam),
and **you** contact them manually. The boundary is **architectural, not a toggle**:
**no** Google Maps / LinkedIn / platform scraping (not even a stub), **no** automated
or bulk outreach, **no** auto-send — follow-up reminders go to **you** (your own
channel, e.g. Telegram), and draft templates are for **you** to copy, personalize and
send yourself. **The default path needs no external credentials.** It is unit-tested
offline (`./tests/prospects/run.sh`), including a test that **asserts the absence of
any send or scrape code path**. See
[Client prospect organizer](#client-prospect-organizer).
