# tests/analytics — web-analytics module + analytics service

Offline test harness for the **web analytics** feature (growth-layer #2): the
self-hosted, privacy-first analytics **service** (`services/analytics/`, Umami) and
the composable **module** (`templates/modules/web-analytics/`). Like the other
suites (`tests/{bot,ctl,startup,mem-budget,health-monitor,preflight}`) it runs with
**no Docker, no Pi, no Umami** — pure logic plus the real on-disk files. It is
**non-mutating**: it never generates into the live tree (full generation is the
operator's sandbox VERIFY step), so the real platform files stay byte-identical.

## Run

```bash
./tests/analytics/run.sh        # exits non-zero on any failure
```

Uses `node` (for the env-gating decision) and `python` + PyYAML (for compose
invariants) when present; each such check is **skipped**, never failed, if the tool
is missing.

## What it checks (and the real bug each guards against)

- **MANIFEST** — `module.manifest` honours the MODULE CONTRACT: `web-analytics`,
  `implemented`, `database: none`, `external_credentials: none`, `files`/`compose`,
  `caddy_routes: none`, a **frontend-only** `base_compatible` (nextjs-app +
  fullstack, **not** dotnet-api), and the two `env` templates — mirrored in
  `env.example`.
- **ENV-GATING** — `lib/analytics.js`: `analyticsConfig()` returns a config **iff
  both** `ANALYTICS_SCRIPT_URL` and `ANALYTICS_SITE_ID` are set (whitespace counts
  as empty) and `null` otherwise — the gate the whole feature hinges on (no
  snippet, no tracking, when unconfigured). Also that a `trackEvent` helper exists
  and is a safe no-op off the browser.
- **FILE PLACEMENT** — per-base subtrees land `template.jsx` + `Analytics.jsx` +
  `lib/analytics.js` at the right path (app root vs `frontend/`); the module ships
  **no root `app/layout.jsx`** (it *nests* via a template, cooperating with the
  base/i18n/auth layouts rather than replacing them); and there is **no dotnet-api**
  files subtree.
- **SNIPPET + PRIVACY** — `Analytics.jsx` is env-gated (`return null` when off),
  uses `next/script`, emits the umami `data-website-id`, and sources the tracker
  from config — and **no Google Analytics / third-party tracker** appears anywhere
  in the module.
- **SERVICE COMPOSE** — `analytics.compose.yml`: exactly `umami` + `umami-db`, both
  **profile-gated** (`analytics`, never auto-start), **no host ports**, `umami` on
  `internal`+`proxy` and `umami-db` `internal`-only, an **isolated dedicated
  volume**, secrets from `.env` only, image **pinned** (never `:latest`).
- **MODULE COMPOSE** — each per-base fragment merges the two `ANALYTICS_*` vars into
  the project's existing web service **only** (no new container, no host ports).
- **WIRING** — the Caddy `analytics.<BASE_DOMAIN>` → `umami:3000` block, the
  `.env.example` ANALYTICS section + secrets, the `analytics.sh` helper (syntax,
  profile, owned services, bad-arg rejection), the `company-site` / `ecommerce`
  presets listing the module, and that the generator **discovers** it as
  implemented.

All prior suites must stay green alongside this one.
