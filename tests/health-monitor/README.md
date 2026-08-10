# Host health monitor — test harness

Unit tests for the decision logic behind
[`scripts/health-monitor.sh`](../../scripts/health-monitor.sh).

The sensor/`df`/`free`/`docker stats` parsing and the **PASS / WARN / FAIL /
SKIP** verdicts live as pure functions in
[`scripts/lib/health-monitor-lib.sh`](../../scripts/lib/health-monitor-lib.sh),
behind a thin set of **seam** functions that wrap the only live inputs (the Pi
thermal sensor, `vcgencmd`, `df`, `du`, `free`, `docker stats`). This harness
sources that library and exercises the pure logic against **fixtures** and
**mocked seams**, so the monitor is verified **without a Pi, Docker, or root** —
exactly how every prior part of this platform was checked on the dev box.

## Run it

```bash
./tests/health-monitor/run.sh
```

It prints a `✓ / ✗ / ~` line per assertion and **exits non-zero if any test
fails**. No Docker, no Pi sensor, no network, and no platform service needs to
be running.

## What it covers

Each case maps to a way the monitor could be wrong:

| Area | Verified with |
| ---- | ------------- |
| **Threshold bands** | `hm_classify_high` — the WARN edge (`>= warn`), the FAIL edge (`>= fail`), and a non-numeric value as a soft WARN, for the temp and disk bands |
| **Temperature parsing** | `hm_parse_vcgencmd_temp` (`temp=47.2'C → 47`) and `hm_parse_thermal_zone` (milli-°C `47234 → 47`), incl. garbage rejection |
| **Throttle decode** | `hm_classify_throttled` — `0x0` PASS, an active ("now") bit FAIL, an only-historical bit WARN, junk SKIP; `hm_throttled_reasons` text |
| **Disk parsing** | `hm_parse_df_pct` / `_avail_kb` / `_used_kb` from `df -P` fixtures, **including a Filesystem source with spaces** (parsed from the right, not a fixed field), and `hm_largest` (backups vs Docker), `hm_pct_of` (divide-by-zero guard) |
| **Memory + swap** | `hm_free_field` (a row/column of `free`, incl. Swap's missing `available`) and `hm_classify_mem` / `hm_classify_swap` (used%, the no-swap = PASS case, total-0 = SKIP) |
| **Container sizes** | `hm_size_to_mib` (`MiB`/`GiB`/`KiB`/`MB`, floats like `1.1GiB`, `0B`, garbage), `hm_stats_used_mib` / `_limit_mib`, `hm_pct_int` |
| **"Near its limit"** | `hm_containers_verdict` (a container ≥ warn% of its **own** limit → WARN, ≥ fail% → FAIL, no rows → SKIP) and `hm_containers_near_limit` (names the offender) on the `docker stats` fixtures |
| **Verdict folding** | `hm_worst` / `hm_severity` — FAIL > WARN > PASS > **SKIP** (a non-measurable check never looks like a problem) |
| **Notifier decision** | `hm_should_notify` alerts **only** on WARN/FAIL (PASS/SKIP are silent) and `hm_kuma_status` maps FAIL→`down`, else `up` |
| **End-to-end** | mocked seams + fixtures folded the way the entrypoint does: a healthy host → PASS (silent), a full disk → WARN (notifies), active throttling → FAIL (notifies, Kuma `down`), memory pressure → WARN/FAIL |
| **The REAL scripts** | `bash -n` syntax of the lib + both scripts, `--help` exits 0, the installed cron line really runs `health-monitor.sh --quiet --status-dir`, and every default threshold has `warn < fail` |

## Fixtures (`fixtures/`)

All committed fixtures are **secret-free** (sensor readings and resource numbers
are not secrets):

- `vcgencmd-temp.txt`, `thermal-zone.txt` — the two CPU-temperature sources.
- `throttled-ok.txt` / `-now.txt` / `-past.txt` — `get_throttled` PASS / FAIL
  (active) / WARN (historical-only) cases.
- `df-root.txt` / `df-warn.txt` / `df-fail.txt` — `df -P` at 22 / 85 / 95 %;
  `df-spaces.txt` — a Filesystem source containing spaces (the right-anchored
  parse regression test).
- `free.txt` / `free-pressure.txt` / `free-noswap.txt` — healthy, RAM+swap
  pressure, and a box with no swap configured.
- `docker-stats.txt` — tab-separated `--format` output incl. `caddy` at 93 % of
  its limit (the near-limit case) and `n8n` in `GiB`; `docker-stats-fail.txt`
  (a container over 95 %) and `docker-stats-ok.txt` (all comfortably under).

> The `docker stats` fixtures are **tab-separated**, matching the exact
> `--format` the entrypoint requests. Regenerate them with `printf '…\t…\n'` if
> editing, so the tabs survive.

## Adding a check

1. Put the pure decision in `scripts/lib/health-monitor-lib.sh` (a parser that
   reads given text, or a classifier that echoes a verdict). Keep every live
   input behind a seam function so it stays mockable.
2. Call it from `scripts/health-monitor.sh`.
3. Add a fixture (if needed) and an assertion here. Re-run `./run.sh`.
