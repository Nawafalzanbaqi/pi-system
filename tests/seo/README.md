# tests/seo — SEO audit engine + seo-toolkit module + seo service

Offline test harness for the **SEO & site quality** feature (growth-layer #3): the
audit **engine** (`services/seo/engine/`), the on-demand auditor **service**
(`services/seo/`), and the composable **module** (`templates/modules/seo-toolkit/`).
Like the other suites (`tests/{analytics,bot,ctl,startup,mem-budget,health-monitor,preflight}`)
it runs with **no Docker, no Pi, no browser, and no AI call** — pure logic plus the
real on-disk files. It is **non-mutating**: it touches only a throwaway temp dir for
the store round-trip, so the real platform files stay byte-identical (full project
generation is the operator's sandbox VERIFY step).

## Run

```bash
./tests/seo/run.sh        # exits non-zero on any failure
```

Uses `node` (engine logic + module logic) and `python` + PyYAML (compose
invariants) when present; each such check is **skipped**, never failed, if the tool
is missing. Fixtures (real audit JSON in `fixtures/`) are generated from the engine
so their shape always matches what the rules consume.

## What it checks (and the real bug each guards against)

- **MANIFEST** — `seo-toolkit/module.manifest` honours the MODULE CONTRACT:
  `implemented`, `database: none`, `external_credentials: none`, `files`/`compose`,
  `caddy_routes: none`, a **frontend-only** `base_compatible` (nextjs-app +
  fullstack, **not** dotnet-api), and the three `env` templates — mirrored in
  `env.example`.
- **RULES** — `rules.js` produces the correct **prioritised** recommendations on
  fixture audits: a bad site surfaces `no-https` (critical, first), missing
  title/meta/h1/sitemap/alt, sorted critical-first; a good site yields **zero**
  findings; an unreachable site yields exactly one `site-unreachable`; a Lighthouse
  audit raises **Core Web Vitals** findings (`lcp/cls/tbt-poor`) the probe never
  produces. Every finding has the required shape/priority/category. This is the
  **free, deterministic** default path.
- **AI-GATING** — `ai.js`: `selectAiProvider` is enabled **only** when both
  `AI_PROVIDER` and `AI_API_KEY` are set; `enrich()` with **no key** (or a provider
  but no key) returns the rule-based result and the **mocked fetch is never called**
  (proves no real API call); with a key it selects the cloud path and the mock fetch
  **is** called once — all via an injected fetch, never a real network request. The
  deterministic findings are unchanged either way.
- **SITEMAP + METADATA** — `sitemap-data.js` / `metadata.js` / `config.js` /
  `robots-data.js`: a localized site emits per-locale URLs (`/ar`, `/en`) **with
  hreflang `alternates.languages`** (+ `x-default`) and locale-prefixed canonicals;
  a single-locale site degrades to one un-prefixed set with no alternates;
  `robots.txt` references the sitemap and disallows `/api` + the auth `/account`
  area; an unconfigured site still renders with a safe absolute fallback.
- **FILE PLACEMENT** — per-base subtrees land `app/sitemap.js`, `app/robots.js`,
  `lib/seo/*` and `components/StructuredData.jsx` at the right path (app root vs
  `frontend/`); the module is **strictly additive** — it ships **no**
  `app/layout.jsx`, `app/page.jsx`, `app/template.jsx` or `middleware.js`, so it
  cannot collide with the base, `i18n-bilingual` or `web-analytics`; routes are
  `force-dynamic` (read runtime env); no dotnet-api subtree.
- **SERVICE COMPOSE** — `seo.compose.yml`: exactly `seo-auditor` + `seo-lighthouse`,
  both **profile-gated** (`seo`, never auto-start), **no host ports**,
  `internal`-only (no `proxy` — no inbound dashboard), **one-shot** (`restart: "no"`
  — proves no always-on browser), built from **pinned** images (never `:latest`),
  each with a memory limit (lighthouse heavier at 1024M, the light default 256M).
  The Dockerfiles pin `node:22-alpine` and the Lighthouse version.
- **MODULE COMPOSE** — each per-base fragment merges the three `SEO_*` vars into the
  project's existing web service **only** (no new container, no host ports), with a
  per-project `__ENVPREFIX__SEO_SITE_URL` override.
- **BOOT PROFILES** — neither seo service appears in `boot-profiles.conf` (it is
  on-demand, never part of any always-on profile).
- **STORE** — `store.js` append/read/latest/list/**trend** round-trips correctly on
  a temp dir (the file-backed, server-less results store).
- **WIRING** — the `.env.example` SEO section + the AI seam keys, the `seo.sh` /
  `seo-lib.sh` / `seo-install-cron.sh` syntax + arg validation + sites parsing, the
  `company-site` / `ecommerce` / `real-estate` presets listing the module, the
  generator **discovering** it as implemented, the committed `sites.example.conf`,
  and the engine `package.json` declaring ESM.

All prior suites must stay green alongside this one.
