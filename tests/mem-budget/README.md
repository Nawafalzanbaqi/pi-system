# Memory budget — test harness

Unit tests for the decision logic behind [`scripts/mem-budget.sh`](../../scripts/mem-budget.sh).

The summation and **PASS / WARN / FAIL** verdicts live as pure functions in
[`scripts/lib/mem-budget-lib.sh`](../../scripts/lib/mem-budget-lib.sh) (the
memory-value converter, the compose-limit parser, the profile flattener and the
budget math) behind a thin set of **seam** functions that wrap the only external
inputs (which compose files to scan, the profile config, total RAM). This harness
sources that library and exercises the pure logic against **fixtures** and
**mocked seams**, so the budget is verified **without Docker or a real Pi** —
exactly how every prior part of this platform was checked on the dev box.

## Run it

```bash
./tests/mem-budget/run.sh
```

It prints a `✓ / ✗ / ~` line per assertion and **exits non-zero if any test
fails**. No Docker, no .NET, no network, and no platform service needs to be
running.

## What it covers

Each case maps to a way the budget could be wrong:

| Area | Verified with |
| ---- | ------------- |
| **Value conversion** | `mb_to_mib` (bytes vs `M`/`G`/`K` suffixes, quotes, garbage) and `mb_literal_mib` (a bare integer is MiB, not bytes) |
| **Per-service limit parsing** | `mb_service_limits` on `fixtures/compose-a.yml` / `compose-b.yml` (both `deploy.resources.limits.memory` and the `mem_limit` short form) |
| **MAX over limits + reservations** | `beta` declares a 512M limit **and** a 128M reservation → must report **512M** (the cap) |
| **Missing-limit detection** | `delta` declares no limit → parsed as **empty** → surfaced as **MISSING** |
| **Profile expansion + dedup** | `mb_flatten` (a profile that references another profile, `label=MiB` literals, de-duplication) |
| **Reference-cycle guard** | `ring1 ⇄ ring2` terminates instead of looping forever |
| **OS-headroom math** | `mb_safe_mib` (`RAM − reserve`, floored at 0) — and the same profile flips **PASS → FAIL** when the reserve is enlarged |
| **Verdict bands** | `mb_verdict_numeric` (the 85% WARN band, the `> safe` FAIL) and `mb_overall_verdict` (a missing limit forces FAIL) |
| **A profile that FITS / EXCEEDS** | integration `budget()` over the mocked map → `small` PASSes, `big` FAILs |
| **The REAL repo** | every discovered platform service declares a limit (the Part A invariant); every member of every real `boot-profiles.conf` profile resolves to a known service or a literal (catches a typo in the profile map) |

## Fixtures (`fixtures/`)

All committed fixtures are **secret-free** (memory limits are not secrets):

- `compose-a.yml` — two services with limits, plus top-level `volumes:` /
  `networks:` blocks whose 2-space keys must **not** be read as services; `beta`
  carries both a limit and a smaller reservation (the MAX case).
- `compose-b.yml` — the `mem_limit` short form (`gamma`) **and** a service with
  no limit at all (`delta`, the missing-limit case).
- `profiles.conf` — fixture profiles: one that fits, one that exceeds, a
  profile-of-profiles, `label=MiB` literals, a no-limit member, and a reference
  cycle.

## Adding a check

1. Put the pure decision in `scripts/lib/mem-budget-lib.sh` (a parser that reads
   a given file, or a classifier that echoes a verdict). Keep every external
   input behind a seam function so it stays mockable.
2. Call it from `scripts/mem-budget.sh`.
3. Add a fixture (if needed) and an assertion here. Re-run `./run.sh`.
