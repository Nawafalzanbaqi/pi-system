# `seo-toolkit` module

On-page **SEO defaults** every site should have, layered onto a generated project:
per-page **meta tags + Open Graph/Twitter**, a **bilingual `sitemap.xml`** and
**`robots.txt`**, and **JSON-LD structured-data** scaffolding — all **bilingual-aware**
(it cooperates with `i18n-bilingual`) and read from runtime env. It is the
generated-site companion to the platform's [SEO auditor](../../../services/seo/README.md)
(`services/seo` + `scripts/seo.sh`): the toolkit puts the on-page signals in place;
the auditor checks them and recommends fixes.

| Manifest | Value |
| -------- | ----- |
| `status` | `implemented` |
| `base_compatible` | `nextjs-app`, `fullstack` (a `dotnet-api` base is skipped — see below) |
| `database` | `none` |
| `external_credentials` | `none` (the optional AI lives in the **audit engine**, not here) |
| `files` | `files` (per-base subtrees) |
| `compose` | `compose` (per-base env-merge into the existing web service) |
| `caddy_routes` | `none` (Next serves `/sitemap.xml` + `/robots.txt` itself) |

## What it adds

All files are **NEW** (the module is strictly additive — it replaces no layout,
page or template), so it composes cleanly alongside `i18n-bilingual`, `auth-sso`
and `web-analytics` with **zero file collisions**:

```
app/sitemap.js              -> /sitemap.xml   (bilingual entries + hreflang)
app/robots.js               -> /robots.txt    (references the sitemap; hides /api, /account)
lib/seo/config.js           -> seoConfig(env): site URL, name, locales (pure, testable)
lib/seo/sitemap-data.js     -> buildSitemapEntries(): bilingual sitemap (pure)
lib/seo/robots-data.js      -> buildRobots() (pure)
lib/seo/metadata.js         -> buildMetadata(): per-page <title>/description/canonical/OG/hreflang
lib/seo/structured-data.js  -> Organization + WebSite JSON-LD (pure)
components/StructuredData.jsx-> emits the JSON-LD <script> (opt-in per page)
```

On a **`fullstack`** base the same files land under `frontend/`. The compose
fragment merges `SEO_SITE_URL` / `SEO_SITE_NAME` / `SEO_LOCALES` into the existing
Next.js service (no new container, no host ports).

## How it cooperates with i18n-bilingual

It does **not** import or depend on the i18n module, but it lines up with it:

- **Locales** come from `SEO_LOCALES` (default `ar,en` — the i18n set) and the
  **default locale** from `NEXT_PUBLIC_DEFAULT_LOCALE` (stamped into every Next.js
  service by the base). When the site is localized, the sitemap emits one entry per
  locale (`/ar…`, `/en…`) with an **`hreflang` `alternates.languages`** map (plus
  `x-default`), and `buildMetadata` sets the locale-prefixed **canonical** + the
  same hreflang map. For a single-locale site (set `SEO_LOCALES` to one locale, or
  leave i18n out) it emits one un-prefixed set.
- `/sitemap.xml` and `/robots.txt` are already in the i18n middleware's **skip
  list**, so they are served as-is (never redirected to a locale). Both routes are
  `force-dynamic` so they read the **runtime** `SEO_SITE_URL` from `.env`.
- `robots.txt` disallows `/account` (the `auth-sso` protected segment) and `/api`,
  so private areas stay out of the index.

## Using the metadata helper + structured data

These two are **opt-in per page** (so the module never has to ship a root layout or
template that would fight i18n / web-analytics). Wire them once in the pages you own:

```jsx
// app/[locale]/page.jsx (or app/page.jsx) — per-page metadata:
import { seoConfig } from '@/lib/seo/config.js';
import { buildMetadata } from '@/lib/seo/metadata.js';

export async function generateMetadata({ params }) {
  const { locale } = await params;            // from the [locale] segment (i18n)
  return buildMetadata(seoConfig(), {
    locale, path: '/', title: 'Home', description: 'Welcome',
  });
}

// …and drop the site-wide JSON-LD into your home page (or a layout you own):
import StructuredData from '@/components/StructuredData.jsx';
export default function Home() {
  return (<><StructuredData />{/* …page… */}</>);
}
```

## Environment

Set these in `.env` (empty templates are appended to the project's section). They
are read **server-side only** (never bundled into client JS):

| Var | Purpose |
| --- | ------- |
| `SEO_SITE_URL` | the site's full public URL → absolute canonical/OG URLs + sitemap. Per-project override: `<PREFIX>SEO_SITE_URL`. |
| `SEO_SITE_NAME` | brand/site name (title fallback, OG, JSON-LD). |
| `SEO_LOCALES` | sitemap/hreflang locales (default `ar,en`). |

The site **still builds with these blank** (sane fallbacks), but set `SEO_SITE_URL`
so the canonical/OG URLs and the sitemap are absolute and correct.

## Submitting your sitemap

Once the site is live at `SEO_SITE_URL`:

1. Confirm `https://<site>/sitemap.xml` and `https://<site>/robots.txt` load.
2. Add the property in **Google Search Console** (and/or **Bing Webmaster Tools**)
   and submit `https://<site>/sitemap.xml`. `robots.txt` already points crawlers at it.
3. Re-audit with `./scripts/seo.sh audit <site>` to confirm the SEO score reflects
   the new sitemap, meta tags and structured data.

## `dotnet-api` base (incompatible — do it server-side)

A `dotnet-api` base has no Next.js frontend, so the module is **skipped** and
recorded in the project's `PROJECT.md`. For a .NET site, add the equivalents in your
app: map `GET /sitemap.xml` and `GET /robots.txt` endpoints, set `<title>` /
`<meta name="description">` / Open Graph tags in your views, and emit an
`application/ld+json` block. The same auditor (`./scripts/seo.sh`) will check them.
