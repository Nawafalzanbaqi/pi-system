# Client prospect organizer (`services/prospects`)

A **self-hosted, operator-owned CRM-lite** for a **manual** client-acquisition
workflow. You — the operator — **find** prospects yourself and **enter** them; this
tool **organizes** the pipeline (status, notes, follow-up reminders) and
**analyzes** a prospect's **own public website** by **reusing the
[`services/seo`](../seo/README.md) engine**; then **you contact them yourself**.
Growth layer #4.

> It is the organizing sibling of the [`services/seo`](../seo/README.md) auditor:
> that audits sites **you own**; this organizes **prospects you found** and analyzes
> **their own public site** as a conversation starter. Same engine, different job.

## ⚠ The boundary — non-negotiable, baked into the architecture (not a toggle)

This tool is for **organization + your own research**, never for harvesting or
mass outreach. These limits are **structural** — they are how the code is built,
not options you can flip on:

- **NO platform scraping.** There is **no** Google Maps, LinkedIn, or
  search-results integration anywhere in this service — **not even an optional
  stub**. The tool never harvests prospect data from any platform. **You** find a
  business (however you legitimately do) and type it in.
- **NO automated or bulk outreach. NO auto-send.** The image carries **no outreach
  transport at all** (no SMTP, no WhatsApp client, no bulk sender). It cannot send
  a message even if asked. Draft templates are produced **for you to copy,
  personalize, and send yourself**, one at a time, through your own channels.
- **Public-site analysis only.** The analyzer fetches **exactly the one public URL
  you entered** (the prospect's own website), once, like any visitor — anyone may
  fetch a public website. It does **not** enumerate, bulk-fetch, or crawl
  third-party platforms.
- **Follow-up reminders go to YOU.** The optional reminder is a nudge to *you* (on
  *your* own channel — e.g. your own Telegram) to reach out manually. It is
  **never** an outbound message to a prospect.
- **No import harvesting.** There is intentionally **no** scraper-fed import. If you
  ever want to bring in a list, it is a **manual CSV you compiled yourself** — and
  even that is optional; single manual entry is preferred. (No CSV importer ships
  here by design.)

The point of the tool is to keep you **organized** and to turn a prospect's **own
public site** into a professional *"here's what I noticed"* artifact you can offer —
not to automate prospecting or contact.

## Reuse, not a parallel analyzer

The analysis path ([`engine/analyze.js`](engine/analyze.js)) contains **no analyzer
of its own**. It imports the **existing** SEO engine directly —
[`probe.js`](../seo/engine/probe.js), [`rules.js`](../seo/engine/rules.js),
[`report.js`](../seo/engine/report.js), [`ai.js`](../seo/engine/ai.js),
[`lighthouse-adapter.js`](../seo/engine/lighthouse-adapter.js) — so a prospect's
report is produced by the **same** deterministic probe, the **same** rules, and the
**same optional, off-by-default AI enrichment** (inert unless `AI_PROVIDER` +
`AI_API_KEY` are set) that growth-layer #3 ships. The Docker image copies both
engine trees so the reuse `import` resolves at runtime.

## Not always-on, no host ports, file-backed

Like the SEO auditor, the organizer sits behind the Compose **profile `prospects`**
and runs as a **one-shot** container (`restart: "no"`) launched by
[`scripts/prospects.sh`](../../scripts/prospects.sh) via `docker compose run --rm` —
it does its work and **exits**, using **zero RAM when idle**. It attaches to the
**`internal`** network only (for the single outbound fetch of a prospect's public
site), publishes **no host ports**, and is never on `proxy`.

The pipeline is a **single small JSON document** under `data/prospects/`
(git-ignored, on the SSD) — file-backed and server-less. No always-on database runs
for a freelancer's handful of prospect records. (The SEO store uses append-only
JSON Lines because audits are *immutable historical events*; prospects are *mutable
entities*, so their current state plus per-record history lives in one document.
See [`engine/store.js`](engine/store.js).)

## Use it

```bash
# Add a prospect YOU found (the only way data gets in — manual entry):
./scripts/prospects.sh add "Acme Dental Clinic" --url https://acme.example --note "met at the expo"

# Work the pipeline:
./scripts/prospects.sh list
./scripts/prospects.sh update acme-dental-clinic --status contacted
./scripts/prospects.sh note acme-dental-clinic "Left a message with reception"
./scripts/prospects.sh update acme-dental-clinic --followup 2026-06-01

# Analyze the prospect's OWN public site (reuses the SEO engine), then read/edit
# the report and share it YOURSELF. A RICH heads-up (score + tier, top 3 findings,
# biggest win, AI lead score if any, report path) is written locally — never to the
# prospect (--locale ar|en):
./scripts/prospects.sh analyze acme-dental-clinic

# ONE command, the FULL automated flow end to end (see below): audit -> verdict ->
# optional AI -> Markdown (+ PDF with --pdf) report saved -> rich alert PUSHED to YOUR
# OWN channel -> follow-up reminder set. Still operator-only; you contact manually:
./scripts/prospects.sh analyze acme-dental-clinic --notify
./scripts/prospects.sh analyze acme-dental-clinic --pdf --notify --locale ar

# See what's due today (a reminder to YOU; --notify pushes to your own channel):
./scripts/prospects.sh followups
./scripts/prospects.sh followups --notify

# Draft a message to COPY, personalize and send yourself (this never sends):
./scripts/prospects.sh template audit-offer acme-dental-clinic
```

## The full automated flow — one command, still inside the boundary

`./scripts/prospects.sh analyze <id> --notify` runs the **entire pipeline end to end**
for a prospect **you already added by hand**. The order is owned by the pure,
unit-tested orchestrator [`engine/run-analysis.js`](engine/run-analysis.js):

1. **Audit** — the **SSRF-guarded** full audit of the prospect's **own public site**
   (all five SEO categories), via the reused [`services/seo`](../seo/README.md) probe.
2. **Verdict** — the deterministic overall score + tier roll-up
   ([`verdict.js`](../seo/engine/verdict.js)).
3. **Optional AI enrichment** — the **same** inert-until-keyed seam the SEO auditor
   uses (no key ⇒ rule-based, **no network call**).
4. **Report saved** — a **Markdown** artifact under `data/prospects/reports/`; with
   `--pdf` (or `PROSPECTS_REPORT_PDF=1`) a print-ready **HTML** is added too, plus a
   **PDF** when `SEO_PDF_RENDERER` names a renderer (it **degrades gracefully** to the
   HTML/Markdown otherwise — no heavy renderer is required on the Pi).
5. **Rich alert to YOU** — the bilingual heads-up ([`engine/alert.js`](engine/alert.js))
   is **pushed to your own channel** (the `PROSPECTS_NOTIFY_CMD` / Uptime-Kuma seam).
6. **Follow-up reminder set** — a nudge to **you**, `PROSPECTS_FOLLOWUP_DAYS` out
   (default 3), surfaced later by `followups`.

> **Two things never change.** You still **ADD** prospects manually (there is no
> scraper/importer), and you still **CONTACT** them manually — the tool only renders a
> copy-paste `template` draft and **never sends anything to a prospect**. The alert and
> the reminder are **to the operator only**; there is no prospect address anywhere in
> the path. Plain `analyze <id>` (no `--notify`) still writes the report and a local
> heads-up file, but does **not** push to your channel or set a reminder.

## Optional configuration (all off by default)

All read from the root `.env` (see the **Client prospect organizer** section of
`.env.example`). The default path needs **no external credentials**.

| Variable | Purpose |
| --- | --- |
| `PROSPECTS_DATA_DIR` | Where the pipeline + reports are stored (default `./data/prospects`). |
| `AI_PROVIDER` / `AI_API_KEY` / `AI_MODEL` / `AI_BASE_URL` | The **shared** SEO AI-enrichment seam — inert unless a key is supplied; usage billed on your own account. |
| `PROSPECTS_UPTIME_KUMA_PUSH_URL` | Optional: push the *operator* follow-up reminder **and** the post-analysis heads-up to an Uptime Kuma monitor. |
| `PROSPECTS_NOTIFY_CMD` | Optional: run your own command for the *operator* messages — the follow-up reminder **and** the rich post-analysis alert (e.g. the Telegram bot bridge, to message **yourself**). The message arrives on stdin, a short label as `$1`. Keep tokens out of git. |
| `PROSPECTS_REPORT_LOCALE` | Optional: language of the post-analysis alert — `ar` (default) or `en` (overridable per run with `analyze --locale`). |
| `PROSPECTS_FOLLOWUP_DAYS` | Optional: how many days out the auto follow-up reminder is set on a `analyze --notify` run (default `3`). |
| `PROSPECTS_REPORT_PDF` | Optional: `1` exports a PDF on every `analyze` (same as passing `--pdf`). Off by default. |
| `SEO_PDF_RENDERER` | Optional (**shared** with the SEO auditor): the opt-in Markdown→PDF renderer. Unset ⇒ keep the print-ready HTML + Markdown (no heavy renderer on the Pi). See [`services/seo/README.md`](../seo/README.md). |

> **One seam, two operator heads-ups, both to YOU.** Follow-up reminders and the
> post-analysis alert share the **same** swappable notifier as the SEO auditor and
> health-monitor. With nothing configured each just writes a local file
> (`last-followups.txt` / `last-analysis-alert.txt`); the alert builder
> ([`engine/alert.js`](engine/alert.js)) is **pure** and unit-tested. There is **no
> prospect address anywhere in this path** — it cannot message a prospect.

## Tested offline

[`tests/prospects/run.sh`](../../tests/prospects/run.sh) exercises the pipeline state
machine, follow-up due-date logic, the analyze path **reusing the SEO engine**
(mocked fetch — **no real network**), report generation from a fixture audit, the
**bilingual operator alert** (pure builder + the `notifyAnalysis` delivery seam via
injected deps), and template rendering. It also drives the **full automated pipeline**
([`engine/run-analysis.js`](engine/run-analysis.js)) through **mocked seams**, proving
the steps run **in order** (audit → report → [pdf] → record → alert → [followup]), that
the five categories + verdict are recorded, the AI env is threaded through, the
Markdown/PDF are saved, the alert is pushed only with `--notify` and the follow-up is set
to today + N — and that **without `--notify` the push and reminder are gated off**.
Throughout it **asserts the absence of any send/scrape code path** and the
**operator-only** alert boundary. It runs with no Docker, no network, and no AI call.
