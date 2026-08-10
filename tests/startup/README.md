# Staged bring-up — test harness

Unit tests for the decision logic behind [`scripts/startup.sh`](../../scripts/startup.sh)
and [`scripts/shutdown.sh`](../../scripts/shutdown.sh).

The stage ORDER, the per-container verify verdict, the retry **backoff/timeout**
math, the profile→stage expansion, generated-project discovery and the
**"a failed stage halts the rest"** driver all live as pure functions (plus a
thin set of **seam** wrappers around Docker) in
[`scripts/lib/startup-lib.sh`](../../scripts/lib/startup-lib.sh). This harness
sources that library and exercises the pure logic against **fixtures** and
**mocked seams**, so the staging is verified **without Docker or a real Pi** —
exactly how every prior part of this platform was checked on the dev box.

## Run it

```bash
./tests/startup/run.sh
```

It prints a `✓ / ✗ / ~` line per assertion and **exits non-zero if any test
fails**. No Docker, no network, and no platform service needs to be running.

## What it covers

Each case maps to a way a staged bring-up could go wrong:

| Area | Verified with |
| ---- | ------------- |
| **Stage order + dependency correctness** | `SU_STAGE_ORDER` (networks first, projects last; proxy < management < dashboard < databases < auth < automation), `su_order_stages`, `su_is_stage` |
| **Registry integrity** | every stage has a description + compose entry; every referenced compose file exists; each member service maps **back** to its stage; every keyed Compose profile / preflight component is valid |
| **Verify decision logic** | `su_probe_verdict` across **healthy / unhealthy / starting** (with a healthcheck) and **running / created / exited / dead / not-created** (the no-healthcheck distroless fallback) |
| **Crash-loop guard** | a restart count that climbs past the threshold ⇒ FAIL, even while momentarily `running`; a currently-`healthy` container is still READY; threshold `0` disables it |
| **Fold many → one** | `su_worst` / `su_fold_verdicts` (any FAIL ⇒ FAIL, any WAIT ⇒ WAIT, empty ⇒ READY) |
| **Inspect parsing** | `su_parse_inspect` turns the seam's TAB line into probe args (and defaults an empty line) |
| **Backoff + timeout** | `su_backoff_delay` (exponential, capped) and `su_deadline_reached` |
| **Profile → stages** | `su_plan_from_services` (group by stage, registry order, literals/unknowns skipped) and `su_expand_tokens` over `fixtures/profiles.conf`, including a reference **cycle** |
| **Compose profile flags** | `su_profiles_for_services` (db engines, the deduped `cache` profile, none needed) |
| **Project discovery** | `su_discover_projects` picks only a dir whose fragment carries the `# pi-system-subdomain:` marker — a generated project — and **not** a platform service dir of the same shape |
| **Halt on failure** | `su_run_plan` with a mocked oracle: a failing stage stops the run and later stages never execute (`SU_EXECUTED`) — the exact driver `startup.sh` uses live |
| **The REAL repo** | every member of every real `boot-profiles.conf` profile maps to a known stage (no orphans); every stage's real compose files are present |

## Fixtures (`fixtures/`)

All committed fixtures are **secret-free**:

- `profiles.conf` — small boot-profiles using **real** pi-system service names so
  expansions map to real stages, with `core` / `dev` / `auth` / `automation` /
  `mixed`, a `label=MiB` literal, and a `ring1 ⇄ ring2` reference cycle.
- `services/acme-portal/acme-portal.compose.yml` — a **generated** project (it
  carries the `# pi-system-subdomain:` marker); discovery must find it.
- `services/proxy/proxy.compose.yml` — a **platform** service dir of the same
  `services/<name>/<name>.compose.yml` shape but with **no** marker; discovery
  must ignore it (so the projects stage never re-deploys the platform).
- `services/notaproject/` — a dir with no matching fragment (skipped).

## Adding a check

1. Put the pure decision in `scripts/lib/startup-lib.sh` (a classifier that
   echoes a verdict, or a planner that takes its inputs as arguments). Keep every
   Docker/system call behind a seam function so it stays mockable.
2. Call it from `scripts/startup.sh` / `scripts/shutdown.sh`.
3. Add a fixture (if needed) and an assertion here. Re-run `./run.sh`.
