# web-analytics — privacy-first, self-hosted analytics for your sites

Layers a **privacy-first web-analytics tracker** onto a generated project so you
can see, for sites you **own** (your own portfolio and the client sites you host),
**who visits, which pages they view, where they came from, and what they click** —
**without Google Analytics** or any third-party tracker that ships visitor data off
the platform. It reports to the platform's own **[analytics service](../../../services/analytics/analytics.compose.yml)**
(self-hosted **[Umami](https://umami.is)**), which needs **no external account**.

This is the **module** half of the feature; the **service** half lives at
`services/analytics/` and is brought up on demand with `./scripts/analytics.sh up`.
See `docs/README.md` → **Web analytics** for the service.

---

## What it captures

Umami is a lightweight, privacy-first analytics engine. With the snippet composed
in, each site reports:

- **Page views** — every page, including App-Router client navigations (the tracker
  follows the History API automatically).
- **Referrers / sources** — where visitors came from.
- **Geography, device, browser, OS** — derived from the request (no precise
  location, no fingerprinting).
- **Custom events / clicks** — anything you choose to mark (see *Tracking custom
  events* below).

All of it is visible in the Umami dashboard at `https://analytics.<BASE_DOMAIN>`.

## Privacy stance (why this, not Google Analytics)

- **Self-hosted only.** The tracker script and all collected data live on **your**
  Pi, in the analytics service's **own isolated database**. Nothing is sent to a
  third party.
- **No cookies, no personal data by default.** Umami does not use cookies and does
  not collect personally identifiable information, so it is GDPR / PECR / CCPA
  friendly out of the box — typically **no cookie banner required**.
- **Strictly opt-in and env-gated.** With the env vars unset, the snippet renders
  **nothing** — no script, no network calls. A project without this module is
  completely unaffected.

---

## How the generator wires it

When you compose `web-analytics` into a project (directly via `--modules
web-analytics`, or through a preset that lists it), the generator:

1. **Env** — appends `ANALYTICS_SCRIPT_URL` and `ANALYTICS_SITE_ID` (empty) to the
   project's `.env.example` section.
2. **Files** (`files/<base>/`) — copies, at the right path for the base
   (`nextjs-app` at the app root; `fullstack` under `frontend/`):
   - `app/template.jsx` — a **root template** that wraps every route and renders
     `<Analytics />`. A template **nests inside** the root layout, so it injects
     analytics **without replacing** the layout — it does **not** touch the base's
     single-locale layout *or* the `i18n-bilingual` module's per-request
     `<html lang dir>` layout, and `auth-sso`'s `/account` segment layout still
     nests cleanly underneath. Nothing else's behaviour changes.
   - `components/Analytics.jsx` — a **server component**: it reads the config and,
     **only when configured**, emits the Umami `<script>` via `next/script`
     (`afterInteractive`, stable id, so it loads exactly once and is de-duplicated
     across client navigations). Otherwise it renders `null`.
   - `lib/analytics.js` — the env-gate (`analyticsConfig` / `isAnalyticsEnabled`)
     and the client-side `trackEvent` helper.
3. **Compose** (`compose/<base>.compose.yml`) — **merges** `ANALYTICS_SCRIPT_URL`
   and `ANALYTICS_SITE_ID` into the project's existing **web** service
   (`__PROJECT_NAME__` for `nextjs-app`, `__PROJECT_NAME__-web` for `fullstack`).
   **No new container, no host ports.**
4. **Records** it under *Active modules* in the project's `PROJECT.md`.

Because the values are read by a **server component** at request time, they are
written into the page HTML and **never bundled into client JS** — so they are plain
container env vars (no `NEXT_PUBLIC_` needed).

## How to point it at the self-hosted analytics service

1. Bring the analytics service up once: `./scripts/analytics.sh up` (it is
   profile-gated and never auto-starts). Ensure Caddy is up too
   (`./scripts/start-proxy.sh`).
2. Open `https://analytics.<BASE_DOMAIN>`, log in (first-boot admin is
   `admin` / `umami` — **change the password immediately**), and **add a website**
   for this project. Copy its **website id**.
3. In `.env`, set:

   ```ini
   # one shared value for every site you host:
   ANALYTICS_SCRIPT_URL=https://analytics.<BASE_DOMAIN>/script.js
   # this site's id from the dashboard:
   ANALYTICS_SITE_ID=<the-website-id-you-copied>
   ```

4. (Re)start the project: `./scripts/project.sh up <name>`. The snippet now loads
   and page views appear in the dashboard.

**Hosting many sites?** Keep `ANALYTICS_SCRIPT_URL` shared and give each project its
own id with a **per-project** override `<PREFIX>ANALYTICS_SITE_ID` (e.g.
`ACME_ANALYTICS_SITE_ID`) — the compose fragment prefers it and falls back to the
shared `ANALYTICS_SITE_ID`. Your **own portfolio site is the primary first use**:
generate it with `web-analytics`, add it as a website in Umami, and you can watch
its traffic the moment it goes live.

## Tracking custom events (clicks, conversions)

Two documented ways, both privacy-preserving:

- **Declarative (no code):** add a `data-umami-event` attribute to any element. The
  tracker records a click event with that name:

  ```jsx
  <a href="/contact" data-umami-event="contact-cta">Get in touch</a>
  <button data-umami-event="signup" data-umami-event-plan="pro">Sign up</button>
  ```

- **Programmatic:** call the shipped helper from a **Client Component** (it is a
  safe no-op when analytics is off, so it never throws):

  ```jsx
  'use client';
  import { trackEvent } from '../lib/analytics'; // adjust the relative path

  export function BuyButton() {
    return <button onClick={() => trackEvent('purchase', { value: 99 })}>Buy</button>;
  }
  ```

---

## Cooperation with the other modules

- **`i18n-bilingual`** — untouched. i18n owns the **middleware** and the **root
  layout**; this module adds only a **root template** (which nests *inside* that
  layout) and reads no i18n internals. The tracker script and the
  `window.umami.track` call both target the analytics subdomain (cross-origin), so
  the i18n locale middleware never intercepts them.
- **`auth-sso`** — untouched. auth-sso protects via a **per-segment** layout
  (`/account`), which nests under this root template; analytics simply also covers
  those pages.
- Composes cleanly alongside `content-admin`, `bookings`, `whatsapp-integration`
  and `local-payments` — it adds only a template + a component + a lib file and an
  env merge, with no file collisions.

## Bases with no frontend (`dotnet-api`)

A `dotnet-api` base serves an API, **not HTML**, so there is nothing to inject and
the module is **incompatible** — the generator skips it and notes that in
`PROJECT.md`. If a .NET app *does* render HTML (Razor Pages / MVC, or a `fullstack`
project — use that base instead), add the tracker by hand to your layout, e.g. in
`_Layout.cshtml` just before `</body>`, gated on configuration:

```cshtml
@if (!string.IsNullOrEmpty(Configuration["ANALYTICS_SCRIPT_URL"]) &&
     !string.IsNullOrEmpty(Configuration["ANALYTICS_SITE_ID"]))
{
    <script defer src="@Configuration["ANALYTICS_SCRIPT_URL"]"
            data-website-id="@Configuration["ANALYTICS_SITE_ID"]"></script>
}
```

Pass the two env vars to the service the same way the Next.js bases do (an
`environment:` block in the project's compose fragment), and it stays env-gated.

---

## Hard rules it honours

- **Privacy-first, self-hosted only** — points solely at the platform's Umami
  service; no Google Analytics, no third-party tracker.
- **Env-gated** — absent when unconfigured; no tracking unless both env vars are set.
- **No database, no external credentials, no host ports, no new container** — it
  only injects a snippet and merges two env vars.
- The analytics **service** it reports to is ARM64, version-pinned, internal DB,
  proxy-only — see `services/analytics/analytics.compose.yml`.
