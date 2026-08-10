# Unified control — test harness

Unit tests for the decision logic behind [`scripts/pi`](../../scripts/pi) (the
operator dispatcher) and [`scripts/status.sh`](../../scripts/status.sh) (the
whole-system snapshot).

`scripts/pi` is a **thin orchestrator**: it routes subcommands, runs the
canonical go-live sequence (**preflight → mem-budget → startup**) halting on the
first failure, and prints an aggregated report — the real work stays in the
existing tools it calls. All of those *decisions* (routing, the step order, the
halt-on-failure driver, scope resolution, flag pass-through) plus the status
*aggregation* (per-container label, the running tally, the overall verdict) live
as pure functions — with a thin set of **seam** wrappers around the only external
calls (invoking each underlying script, resolving a container) — in
[`scripts/lib/ctl-lib.sh`](../../scripts/lib/ctl-lib.sh). This harness sources
that library and exercises the logic against **fixtures** and **mocked seams**,
so the orchestration is verified **without Docker or a real Pi** — exactly how
every prior part of this platform was checked on the dev box.

## Run it

```bash
./tests/ctl/run.sh
```

It prints a `✓ / ✗ / ~` line per assertion and **exits non-zero if any test
fails**. No Docker, no network, and no platform service needs to be running.

## What it covers

Each case maps to a way the control layer could go wrong:

| Area | Verified with |
| ---- | ------------- |
| **Subcommand routing** | `ctl_route` maps `up/down/status/check/health/doctor` (and the `runbook` alias) `/help/-h/--help/""` and rejects an unknown verb |
| **Flag detection & pass-through** | `ctl_has_flag`, `ctl_value_flag` (`--ram 8192` / `--ram=8192`), `ctl_scope_tokens` (values of `--profile`/`--services`, comma/space split), `ctl_skip_flags` (`--dry-run` / `--skip-checks` / `--skip-preflight` / `--skip-mem-budget`), and `ctl_forward_startup_args` (originals preserved **+ `--skip-checks` appended**, so startup never re-runs the gates) |
| **`up`/`check` step order** | `ctl_up_steps` (default = preflight→mem-budget→startup; dry-run / skip variants) and `ctl_check_steps` (the read-only pair only) |
| **Halt on failure (driver)** | `ctl_run_sequence` with a **mocked oracle**: a failing step stops the run and later steps never execute (`CTL_EXECUTED`) — the same driver `pi` uses live |
| **Sequencing via the REAL oracle** | `ctl_step_run` over **mocked seams**: `up` calls **preflight → mem-budget → startup** in that order and **halts** if an earlier step fails (mem-budget/startup are never called); `check` runs only the pair |
| **Scope resolution** | `ctl_preflight_components` expands a profile to the de-duplicated preflight component scope over `fixtures/profiles.conf` (and the literal `app-x=512` is ignored) |
| **Status labels / verdicts** | `ctl_status_label` (healthcheck vs distroless-state vs absent), `ctl_status_overall` (UP / DOWN / DEGRADED across broken / up / host signals), `ctl_status_tally`, and `ctl_health_verdict` (extracting `PASS/WARN/FAIL` from a health-monitor run) |
| **Per-service probe** | `ctl_probe_service` over **mocked** `su_service_container_id` + `su_inspect`: running / healthy / exited / unhealthy / absent each classify correctly — reusing the **same** probe logic the staged bring-up uses |
| **Doctor (next command)** | `ctl_status_verdict_word` (extracting `UP/DOWN/DEGRADED/UNKNOWN` from a `status.sh` run) and `ctl_next_command` — every branch (no `.env` → `setup.sh`; weak secrets → `check-secrets.sh`; ready+down → `pi up`; degraded/up → `pi status`; unknown → `pi check`), with the no-`.env` branch taking precedence and a non-empty reason on each |
| **Integrity vs the real repo** | every seam targets an existing `scripts/*.sh`; `scripts/pi`, `scripts/status.sh` and `scripts/lib/ctl-lib.sh` all parse (`bash -n`); the **real** `boot-profiles.conf` resolves `core` to the expected component scope |

## Fixtures (`fixtures/`)

All committed fixtures are **secret-free**:

- `profiles.conf` — a small boot-profiles file using **real** pi-system service
  names (so they map to real preflight components), with `core` / `dev` / `auth`
  / `automation`. Kept separate from the real `infrastructure/boot-profiles.conf`
  so the expected scope expansions stay fixed regardless of edits to the real one.

## Adding a check

1. Put the pure decision in `scripts/lib/ctl-lib.sh` (a function that echoes its
   result and `return 0`s). Keep every external call (invoking a script,
   resolving a container) behind a **seam** so it stays mockable.
2. Call it from `scripts/pi` / `scripts/status.sh`.
3. Add an assertion here (mock the relevant seam if it touches the system) and
   re-run `./run.sh`. The four sibling suites must stay green too.
