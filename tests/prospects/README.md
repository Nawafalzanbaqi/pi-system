# Prospect organizer tests (`tests/prospects`)

Offline unit tests for the **client prospect organizer** (growth layer #4) — the
engine in [`services/prospects/engine`](../../services/prospects/engine), the helper
[`scripts/prospects.sh`](../../scripts/prospects.sh) + its
[lib](../../scripts/lib/prospects-lib.sh), and the
[service compose](../../services/prospects/prospects.compose.yml). They run with
**no Docker, no network, no browser, and no AI call** — pure logic, the real on-disk
files, and fixtures — mirroring `tests/seo/run.sh` and the other suites.

```bash
./tests/prospects/run.sh        # exits non-zero on ANY failure
```

## What it covers

| Section | Why it matters |
| --- | --- |
| **PIPELINE** | `pipeline.js` — record creation, the validated status **transitions** (the funnel), notes, follow-up set/clear, slug/validation. |
| **FOLLOW-UPS** | `followups.js` — due-date logic on fixed dates: overdue / today / future / closed-excluded. Reminders are to the **operator**. |
| **STORE** | `store.js` — `loadDb`/`saveDb`/`uniqueId`/`list`/`writeReport` round-trip in a temp dir; missing store is empty. |
| **ANALYZE-REUSE** | `analyze.js` **reuses** the `services/seo` engine via a **mocked fetch** (no real network); produces a report; there is **no parallel analyzer**. |
| **REPORT + AI-GATING** | report generated from a **fixture audit** (the SEO `audit-bad.json`); the reused AI seam stays **inert without a key** and enriches only with one (mocked — no real call). |
| **TEMPLATES** | `templates.js` — bilingual drafts (intro/followup/audit-offer) with operator `[PLACEHOLDERS]`; analysis-aware; the renderer makes no network call. |
| **NO-SEND / NO-SCRAPE** | **asserts the architectural boundary**: zero engine dependencies, no transport/scraper library tokens, no send/scrape/import/crawl action, no `send` subcommand, no parallel analyzer modules. |
| **SERVICE COMPOSE** | profile-gated, internal-only, **no host ports**, one-shot (`restart: "no"`), pinned image, memory limit; Dockerfile copies **both** engines (reuse) and is never `:latest`. |
| **BOOT PROFILES** | the prospects service is in **no** boot profile (never always-on). |
| **WIRING** | `.env.example` section, helper/lib/cron syntax + argument validation, ESM engine. |

## Fixtures

- [`fixtures/prospects-seed.json`](fixtures/prospects-seed.json) — a small committed
  pipeline (varied statuses + follow-up dates) for deterministic due-date / store
  assertions.
- The report/AI-gating tests reuse the SEO fixture
  [`tests/seo/fixtures/audit-bad.json`](../seo/fixtures/audit-bad.json) — proving the
  analysis path runs on the **same** audit shape the SEO engine produces.
