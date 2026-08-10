# Preflight check — test harness

Unit tests for the decision logic behind [`scripts/preflight.sh`](../../scripts/preflight.sh).

The checks that decide **PASS / WARN / FAIL** live as pure functions in
[`scripts/lib/preflight-lib.sh`](../../scripts/lib/preflight-lib.sh) (classifiers,
parsers, the component registry) behind a thin set of **seam** functions that
wrap every external call (`docker`, `uname`, `df`, `/proc`, the registry). This
harness sources that library and exercises the pure logic against **fixtures**
and **mocked command outputs**, so preflight's verdicts are verified **without a
live Docker or a real Pi** — exactly how every prior part of this platform was
checked on the dev box.

## Run it

```bash
./tests/preflight/run.sh
```

It prints a `✓ / ✗ / ~` line per assertion and **exits non-zero if any test
fails** (so it drops straight into CI or a pre-commit hook). No Docker, no .NET,
no network, and no platform service needs to be running.

## What it covers

Each case maps to a likely first-run failure preflight is meant to catch early:

| Area | Verified with |
| ---- | ------------- |
| **Missing `.env`** | `pf_missing_required` on an absent file → all required vars reported |
| **Missing / empty required var** | `pf_missing_required` on `fixtures/env-partial.env` |
| **Value extraction (no `source`)** | quotes, CRLF, empty/absent handling |
| **Weak secret (mapping)** | `pf_classify_secret_audit` on mocked check-secrets output |
| **Weak secret (REAL)** | the actual [`scripts/check-secrets.sh`](../../scripts/check-secrets.sh) run against a generated weak `.env` in a throwaway dir — must exit non-zero |
| **Strong secrets (REAL)** | same, against a generated strong `.env` — must exit zero |
| **arch / boot-media** | `pf_arch_verdict`, `pf_sdcard_verdict` |
| **Low disk / low RAM** | `pf_classify_min` boundaries + mocked `df` / `/proc/meminfo` seams |
| **Bad compose (collisions)** | `pf_extract_host_ports` / `pf_extract_container_names` + `pf_find_duplicates` on `fixtures/compose-collision.yml` |
| **Bad compose (parse)** | OPTIONAL — real `docker compose config` on `fixtures/compose-invalid.yml`, **auto-skipped when Docker is absent** |
| **Tag missing / no arm64 / offline** | `pf_check_image` with a **mocked registry seam**, plus `pf_manifest_arm64` / `pf_classify_manifest_error` |
| **Registry vs the real repo** | every compose file the registry references exists; the real platform files have no host-port / container-name collisions |

## Fixtures (`fixtures/`)

All committed fixtures are **secret-free**:

- `env-partial.env` — variable presence only (present / empty / quoted / absent).
- `compose-good.yml` — a clean snippet (literal + interpolated images, proto-aware
  ports incl. the `443/tcp` + `443/udp` non-collision, a commented bootstrap port,
  named volumes).
- `compose-collision.yml` — two services sharing a host port **and** a
  `container_name` (both must be flagged).
- `compose-invalid.yml` — invalid YAML for the docker-gated real-parse test.
- `manifest-arm64.json` / `manifest-amd64only.json` — `docker manifest inspect`
  shapes for the arm64 detection.

Secret-bearing `.env` files (strong / weak) are **generated at runtime** into a
temp dir with fake values — never committed — so the repo keeps no secrets.

## Adding a check

1. Put the pure decision in `scripts/lib/preflight-lib.sh` (a classifier that
   echoes a verdict, or a parser that reads a file/stdin). Keep all system access
   behind a seam function so it stays mockable.
2. Call it from `scripts/preflight.sh` and `record` its verdict.
3. Add a fixture (if needed) and an assertion here. Re-run `./run.sh`.
