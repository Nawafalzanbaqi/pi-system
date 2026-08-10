# SEO & site quality (`services/seo`)

A **scheduled / on-demand auditor** for the sites you **own** — your portfolio and
the client sites you host — plus a **free, deterministic recommendations engine**
with an **optional, off-by-default AI** enrichment. It scores each site
(performance, SEO, accessibility, best practices), stores results over time so you
can see trends, and turns them into a prioritised, actionable report. Growth
layer #3.

> This is about **site quality / SEO of the running sites**. It is the sibling of
> [`services/quality`](../quality/README.md), which is about **code quality** of a
> generated project (lint / analyzers / vuln scan). Different jobs, different tools.

## Honest Pi reasoning: why a probe by default, Lighthouse only on opt-in

A real Lighthouse run drives **headless Chromium**, which is **heavy on a Pi 5**
(hundreds of MB of RAM and real CPU per run). An always-on browser would
permanently tax the device for a job that runs a few times a day — exactly the
always-on cost this platform avoids. So:

- **Default engine — a lightweight Node probe (no browser).** It fetches each page
  once over HTTP, runs deterministic on-page checks (title, meta description,
  headings, `lang`/`dir`, canonical, viewport, Open Graph, alt text, robots.txt &
  sitemap.xml reachability, JSON-LD), measures basic timing/size metrics, and
  computes Lighthouse-**style** category scores from documented rules
  ([`engine/scoring.js`](engine/scoring.js)). It is **free**, needs **no
  credentials**, starts in milliseconds, and uses a tiny memory footprint.
- **Opt-in engine — real Lighthouse (headless Chromium).** For a true Lighthouse
  Performance score + **measured Core Web Vitals** (LCP / CLS / TBT), run
  `./scripts/seo.sh audit <site> --engine lighthouse`. It is a **separate, heavier
  image** ([`Dockerfile.lighthouse`](Dockerfile.lighthouse), 1 GB limit) and is
  **never the default** — run it sparingly, one site at a time.

Both engines feed the **same** storage / rules / report pipeline, so a probe run
and a Lighthouse run produce comparable reports.

## Not always-on, no host ports, scheduled like the rest

Both services sit behind the Compose **profile `seo`** and run as **one-shot**
containers (`restart: "no"`) launched by [`scripts/seo.sh`](../../scripts/seo.sh)
via `docker compose run --rm` — they do the audit and **exit**, so they use **zero
RAM when idle**. They attach to the **`internal`** network only (for outbound
access to your sites' public URLs), publish **no host ports**, and are scheduled
with the existing host-cron pattern via
[`scripts/seo-install-cron.sh`](../../scripts/seo-install-cron.sh) — **not** an
always-on browser.

## Results store — file-backed, server-less

Audit history is a few rows per site, written a handful of times a day. Running a
database **server** 24/7 (256–512 MB of RAM) just to hold that would be the very
always-on cost we avoid. So results are stored as **append-only JSON Lines keyed by
service name**, one file per site, under `data/seo/` (git-ignored, on the SSD) — a
file-backed store that is **internal-only by nature** (a local file, no network, no
ports), survives restarts, costs **zero RAM idle**, and is trivial to read back for
trends. Same reasoning the quality gate uses to reject an always-on analyzer, and
the backup / health-monitor use to write under `data/`. See
[`engine/store.js`](engine/store.js).

```
data/seo/
├── sites.conf                # YOUR site list (copy from sites.example.conf)
├── audits/<name>.jsonl       # append-only history (one audit per line)
├── latest/<name>.json        # the most recent audit (quick reads)
├── reports/<name>-<ts>.md    # the human-readable report per run
├── reports/<name>-<ts>.html  # OPTIONAL PDF export: print-ready HTML (always)
├── reports/<name>-<ts>.pdf   # OPTIONAL PDF export: the PDF (only with a renderer)
└── last-summary.txt          # the last run's one-line summary (notifier default)
```

## Analysis depth — one clear cost-vs-depth dial per run

Every audit has the same deterministic engine. **Depth** decides which *optional*
layers run on top, so the operator picks **cost vs depth** per run:

| `--depth`  | AI cost          | What runs                                             | When to use                                  |
| ---------- | ---------------- | ----------------------------------------------------- | -------------------------------------------- |
| `quick`    | **FREE** · 0 calls | Rules-only (the deterministic path on its own).      | Fast triage; keeping cost down on the Pi.    |
| `standard` | ~**1** AI call   | Rules + the single-call AI enrichment (`ai.js`).      | Sensible default when an AI key is set.      |
| `deep`     | ~**7** AI calls  | Rules + enrichment + the full **specialist panel**.   | High-stakes runs; the trustworthy "technical team". |

**Precedence** (validated *before* Docker, so a typo never spends a container):

1. explicit `--depth <level>` wins;
2. legacy `--panel` is treated as `--depth deep` (back-compat with growth-layer #3);
3. `SEO_DEFAULT_DEPTH` in `.env` pins the per-machine default;
4. otherwise: `standard` when an AI key is set, `quick` when it isn't (the engine
   never half-enables AI).

The chosen depth is recorded on the audit and surfaced in the report header so a
reader can tell which level produced it at a glance. The same `--depth` flag is
accepted by `scripts/prospects.sh analyze` (the prospect-side reuses the same
SEO engine, so cost behaves identically). Costs assume `AI_PROVIDER`+`AI_API_KEY`
are set on **your** account; with no key every level stays at **0** AI calls
(deterministic fallback for `standard` / `deep`, same as `quick`).

```bash
# Free triage (the deterministic rules; never makes an AI call):
./scripts/seo.sh audit happy-teeth --depth quick

# Default when AI is configured (~1 AI call):
./scripts/seo.sh audit happy-teeth --depth standard

# The "technical team" — multi-specialist panel (~7 AI calls), high-stakes only:
./scripts/seo.sh audit happy-teeth --depth deep

# Back-compat: --panel still works (== --depth deep).
./scripts/seo.sh audit happy-teeth --panel
```

## Competitor comparison (manual URLs)

`./scripts/seo.sh audit <site> --competitor <url> [--competitor <url> ...]` adds a
side-by-side **"Competitor comparison"** section to the report. Up to **3**
competitor URLs (the operator types them in — there is **no scrape, no discovery**).
Each URL goes through the **same SSRF-guarded probe** as the primary; a private /
redirecting / unreachable competitor is **recorded** in the report with the
non-leaky reason and **never** fails the run.

Every number in the comparison comes from a real audit field — there is no
synthesis. The performance gap surfaces the response-time pair (`Loads in Xs vs
Ys`) using each side's `audit.metrics.responseMs`. The same flag is accepted by
`./scripts/prospects.sh analyze <id> --competitor <url> ...`.

```bash
# Audit your own site with two competitors:
./scripts/seo.sh audit happy-teeth \
    --competitor https://comp-a.example.com \
    --competitor https://comp-b.example.com
```

## Telegram "audit this URL" (operator-only, SSRF-guarded)

The Telegram management bot exposes two extra commands that take **one** http(s)
URL the operator pastes:

- `/audit_url <url>` — standard-depth audit (`~1` AI call when an AI key is set).
- `/panel_audit_url <url>` — deep-depth audit (full multi-specialist panel,
  `~7` AI calls).

The URL travels as a **single argv element** end-to-end (never interpolated, never
`eval`'d). The bridge runs the **SSRF guard** (`services/seo/engine/ssrf-check.js`)
**before** spawning the audit container, so a URL pointing at an internal host /
using a non-http(s) scheme / embedding credentials is refused at the boundary; the
engine's probe **re-checks every hop** (DNS-rebinding defence). The
**`TELEGRAM_ALLOWED_IDS`** allowlist fail-closed gates every command — an empty
allowlist authorizes no one. Competitor comparison stays a CLI feature (it needs
multiple URLs; the bot is single-URL only).

## Recommendations engine — free by default, AI optional & inert

[`engine/rules.js`](engine/rules.js) turns an audit into a clear, **prioritised**
list of recommendations (critical → low) using fixed rules — **no API, no AI, no
network**. This always runs and always produces a sane report.

[`engine/ai.js`](engine/ai.js) adds an **optional** AI enrichment using the
platform's **swappable-provider** pattern (the same one `whatsapp-integration` and
`local-payments` use). It is **fully coded but inert** until **both**
`AI_PROVIDER` and `AI_API_KEY` are set in `.env`:

| `AI_PROVIDER` | `AI_API_KEY` | Result |
| ------------- | ------------ | ------ |
| unset / `none` | — | **Rule-based only** (the default). No key, no network, no cost. |
| set (e.g. `openai`) | **unset** | Stays **rule-based** (it never half-enables). |
| set (e.g. `openai` / `anthropic` / `compatible`) | **set** | AI **enriches** the rule-based report. |

When enabled it calls an **OpenAI/Anthropic-compatible** chat endpoint (override
with `AI_MODEL` / `AI_BASE_URL`). **No key is committed or required now**, and when
you do supply one, **usage is billed on your own account**. The AI block only ever
*adds* to the deterministic report — it never replaces it.

## Optional PDF export of a report (off by default — Pi-aware)

A report is Markdown. `./scripts/seo.sh pdf <site>` turns it into a polished,
**client-facing artifact**: it builds the **bilingual prospect report** from the
site's latest stored audit and **always** writes a clean, self-contained,
**print-ready HTML** (plus the Markdown) under `data/seo/reports/`. A `.pdf` is
written **only if you opt in** to a renderer.

**Why no bundled renderer:** a faithful HTML → PDF renderer means **headless
Chromium** (puppeteer), **Qt/WebKit** (wkhtmltopdf), or **Pango/Cairo**
(WeasyPrint) — all **heavy** and/or pulling native libraries. Installing one by
default — let alone running it always-on — is exactly the cost this platform
avoids (the same reasoning that makes the Lighthouse engine a separate, opt-in
image). So this ships **none**. The default export degrades gracefully:

- **Default (zero install, recommended):** open the generated `…-<ts>.html` and
  **“Save / Print as PDF”** in any browser. The rendering happens on **your**
  machine, not the Pi (**zero Pi cost**), and the browser renders **Arabic / RTL**
  and fonts perfectly. The pure, dependency-free `Markdown → HTML` core lives in
  [`engine/md-to-html.js`](engine/md-to-html.js) and is unit-tested.
- **Opt-in (a ready-made `.pdf`):** install a renderer module and name it in
  `SEO_PDF_RENDERER`. It is **dynamically imported**, so a blank/missing/
  incompatible value simply degrades back to the Markdown + HTML — it is never an
  error. The renderer contract is small: a module exporting
  `htmlToPdf(html, opts)` (or a default function) that returns a PDF `Buffer`.
  `SEO_PDF_RENDERER` may be an **installed package name** *or* a **path to a local
  renderer script** that exports that contract. Pick a **pinned, ARM64-safe** one
  and treat it like Lighthouse — **one-shot, occasional**, never always-on.

```bash
# Build + export the latest report for a site (HTML always; PDF only if opted in):
./scripts/seo.sh pdf happy-teeth                 # Arabic (the platform default)
./scripts/seo.sh pdf happy-teeth --locale en     # English

# Output (under data/seo/reports/), sharing one <name>-<ts> stem:
#   happy-teeth-<ts>.md     the exact Markdown that was converted
#   happy-teeth-<ts>.html   a clean, A4 print-ready HTML  (always)
#   happy-teeth-<ts>.pdf    the PDF                        (only with a renderer)

# Convert an EXISTING report file instead of rebuilding (engine-direct):
#   node services/seo/engine/audit.js report-pdf --name happy-teeth \
#        --md data/seo/reports/happy-teeth-<ts>.md
```

> **Match the Lighthouse opt-in:** like `--engine lighthouse`, the PDF path is
> profile-gated, one-shot, off by default, and reuses the **same** report pipeline.
> If you want a heavier, guaranteed-faithful renderer (e.g. a pinned WeasyPrint or
> headless-Chromium tool), package it as a **separate one-shot container** exactly
> like [`Dockerfile.lighthouse`](Dockerfile.lighthouse) and have it call the shared
> `md-to-html.js` core — keep it out of the default image.

## Usage

```bash
# 1) Create your site list (the sites you OWN — portfolio + hosted clients):
mkdir -p data/seo && cp services/seo/sites.example.conf data/seo/sites.conf
$EDITOR data/seo/sites.conf            # add "<name> <url>" lines

# 2) Audit (default = the free, light probe engine):
./scripts/seo.sh audit happy-teeth     # one site
./scripts/seo.sh audit all             # every listed site, one at a time
./scripts/seo.sh audit my-site --url https://example.com   # ad-hoc URL

# 3) See results + trends + the report:
./scripts/seo.sh list                  # latest scores per site
./scripts/seo.sh trend happy-teeth     # first → latest per category
./scripts/seo.sh recommend happy-teeth # re-print recommendations (no new probe)
./scripts/seo.sh status

# 4) (Optional) the heavy, real Lighthouse engine for true Core Web Vitals:
./scripts/seo.sh audit my-site --engine lighthouse

# 4b) (Optional) export a report as a clean HTML (+ PDF if you opted in):
./scripts/seo.sh pdf happy-teeth        # see "Optional PDF export" above

# 5) Schedule a weekly audit (host cron, one-shot container):
./scripts/seo-install-cron.sh          # add --dry-run to preview, --remove to undo
```

## On the generated-site side: the `seo-toolkit` module

The auditor checks sites; the
[`seo-toolkit`](../../templates/modules/seo-toolkit/README.md) **module** gives a
generated site the on-page SEO defaults the auditor looks for — meta tags, Open
Graph, a **bilingual** `sitemap.xml` and `robots.txt`, and JSON-LD scaffolding —
cooperating with `i18n-bilingual`. Add it with `--modules seo-toolkit` (it is in
the `company-site`, `ecommerce` and `real-estate` presets). The two halves are
independent: you can audit any site you own, and you can add the module to any
site you generate.

## Requirements

- Docker (the audit runs in a one-shot container); no Node need be installed on the
  host. The image is built locally from the pinned, ARM64 `node:22-alpine` base.
- Outbound internet for a run (to fetch your sites). No platform service needs to be
  up. The default path needs **no external credentials**; only the optional AI
  enrichment needs a key you supply.
