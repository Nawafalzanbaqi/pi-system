# Modules layer — composable features

A **module** is a self-contained feature that can be layered on top of any
[base](../base/README.md) shape: bookings, a content admin, bilingual i18n, a
WhatsApp integration, local payments, and so on. Modules are how this platform
gets **low-maintenance variety** — you build a feature once, then compose it into
many projects (directly via `--modules`, or in bulk through a sector
[preset](../presets/README.md)) instead of re-writing it per client.

> **Status of this layer.** Implemented today: the contract below, the
> **`hello-module`** reference, and **eight real feature modules** —
> [**`i18n-bilingual`**](i18n-bilingual/README.md) (Arabic/English + RTL),
> [**`content-admin`**](content-admin/README.md) (a Directus headless CMS),
> [**`bookings`**](bookings/README.md) (appointment / reservation scheduling),
> [**`auth-sso`**](auth-sso/README.md) (optional single sign-on via the platform's
> Keycloak),
> [**`whatsapp-integration`**](whatsapp-integration/README.md) (WhatsApp messaging),
> [**`local-payments`**](local-payments/README.md) (mada / card checkout),
> [**`web-analytics`**](web-analytics/README.md) (privacy-first, self-hosted
> visitor analytics — no Google Analytics),
> and [**`seo-toolkit`**](seo-toolkit/README.md) (on-page SEO defaults — meta +
> Open Graph, a bilingual sitemap.xml & robots.txt, JSON-LD — the generated-site
> companion to the [SEO auditor](../../services/seo/README.md)).
> `whatsapp-integration` and
> `local-payments` need **external credentials** to go *live*, but ship with a
> working **mock / sandbox** provider so they compose and run **now** with no
> external account (a pure env change flips each to live — see their `SETUP.md`);
> `web-analytics` needs **no external account** at all (it reports to the platform's
> own analytics service). **No feature modules remain planned.** The generator
> composes implemented modules in
> (respecting each module's `base_compatible`), and would skip any
> requested-but-planned module **gracefully**, recording it as a TODO in the
> generated project's `PROJECT.md`, so a project is never left in a broken state.

---

## The module contract (`module.manifest`)

Every module is a folder under `templates/modules/<module-name>/` containing a
**`module.manifest`** file plus whatever assets it contributes. The manifest is a
simple, line-based `key: value` file (so the generator can parse it with plain
shell — no YAML dependency). Keys:

| Key                    | Required | Meaning                                                                                                  |
| ---------------------- | -------- | -------------------------------------------------------------------------------------------------------- |
| `name`                 | yes      | The module's identifier (must equal the folder name; `^[a-z][a-z0-9-]*$`).                                |
| `description`          | yes      | One line describing what the module does.                                                                 |
| `status`               | yes      | `implemented` (the generator will compose it in) or `planned` (the generator skips it, records a TODO).   |
| `base_compatible`      | yes      | Comma-separated base shapes the module supports: any of `dotnet-api`, `nextjs-app`, `fullstack`, or `all`.|
| `database`             | yes      | DB engine the module needs: `postgres` \| `mysql` \| `mongo` \| `none`.                                   |
| `external_credentials` | yes      | `none`, or a one-line description of the external account / approved API keys required to activate it.    |
| `env`                  | yes      | Comma-separated env var names the module needs, **as empty templates** (or `none`). Never values.         |
| `files`                | yes      | Relative path to a tree of **source files** the module layers onto the project (or `none`). See below.    |
| `compose`             | yes      | Relative path to the compose fragment the module contributes, or `none`. May name a single file (base-agnostic) **or a directory of per-base fragments** — see below. |
| `caddy_routes`        | yes      | Relative path to a Caddy snippet the module adds to its project's site block, or `none`.                  |

A module folder may therefore contain:

```
templates/modules/<name>/
├── module.manifest        # the declaration above (required)
├── env.example            # the empty env templates listed in `env:` (optional, documentation)
├── files/                 # source files copied into the project — the `files:` tree (optional)
│   └── <base>/            #   optional per-base subtree; overrides the generic files/ for that base
├── service.compose.yml     # the compose fragment named by `compose:` (optional)
├── caddy.snippet           # the Caddy routes named by `caddy_routes:` (optional)
└── README.md               # what it is + how to wire it (recommended)
```

### What "compose it in" means

First the generator checks `base_compatible`: if the project's base shape isn't
listed (and it isn't `all`), the module is **skipped** and recorded under
**Modules not applied (incompatible base)** in `PROJECT.md` — e.g. a frontend-only
module on a `dotnet-api` base — so it is never composed incorrectly (the module's
README points to the alternative it offers for that base). Otherwise, for an
**implemented**, base-compatible module the generator:

1. **Env** — appends the module's `env` vars (empty templates, each labelled with
   the module name) to the project's section in `.env.example`.
2. **Files** — if `files:` names a tree, copies it into the project with the base
   placeholders substituted, choosing `files/<base>/` when present so each base
   gets code at the right path (`nextjs-app` at the app root; `fullstack` under
   `frontend/`). This is how an **in-app** module layers real source onto the base
   (e.g. `i18n-bilingual` adds locale routes, dictionaries and a switcher). Copied
   files may **replace** base files (an i18n root layout replaces the base's
   single-locale one) and obey the same hard rules as the base they extend.
3. **Compose** — substitutes the base placeholders into the module's compose
   contribution and writes it next to the project's main fragment as
   `services/<name>/<name>.<module>.compose.yml`. `scripts/project.sh` loads every
   `services/<name>/<name>.*.compose.yml` alongside the main fragment, so the
   module's service(s) come up with the project. `compose:` may name **either**:
   - a single **file** (base-agnostic) — e.g. `content-admin`'s
     `service.compose.yml`, which ships its own standalone container(s); or
   - a **directory** of **per-base fragments** — the generator picks
     `<dir>/<base>.compose.yml`. This is the same per-base idea as `files/<base>/`,
     and it is what lets a module **merge config into the base's own service(s)**
     whose names differ by shape (`<name>` vs `<name>-api` / `<name>-web`). For
     example `auth-sso` (`compose: compose`) ships `compose/dotnet-api.compose.yml`,
     `compose/nextjs-app.compose.yml` and `compose/fullstack.compose.yml`, each
     re-declaring the existing service(s) with extra `environment:` only (Compose
     merges `environment` maps) — adding **no** new container and **no** host ports.
     A directory with no fragment for the current base is skipped cleanly.

   Module fragments follow the same hard rules as the base: ARM64, pinned tags,
   **no host ports**, mem limit, `no-new-privileges`, attached to the shared
   `internal` / `proxy` networks.
4. **Caddy** — if `caddy_routes:` is a file, substitutes placeholders and appends
   it inside the project's existing Caddy site block (no new host ports; routes
   are paths/handlers under the same subdomain).
5. **Record** — lists the module under **Active modules** in the project's
   generated `PROJECT.md`.

If the module is **planned** (or not yet present as a folder), the generator skips
all of the above and records it under **Planned modules — TODO** in `PROJECT.md`,
including the external-credential note if any.

### Placeholders available to modules

Module `files:`, `compose:` and `caddy_routes:` content may use the same
placeholders as the base (`__PROJECT_NAME__`, `__SUBDOMAIN__`, `__DB_ENGINE__`,
`__DB_HOST__`, `__DB_PORT__`, `__DB_CONNECTION_STRING__`, `__DB_URL__`,
`__ENVPREFIX__`, `__DEFAULT_LOCALE__`, `__DEFAULT_DIR__`, `__GENERATED_DATE__`,
`__TEMPLATE__`) — they are substituted identically (e.g. i18n's `i18n/config.js`
falls back to `__DEFAULT_LOCALE__`, and its dictionaries use `__PROJECT_NAME__`).

---

## Reference module: `hello-module`

[`hello-module/`](hello-module/) is the **minimal, safe** reference that follows
the contract exactly. By design it contributes **only empty env templates** — no
container, no Caddy route, no database, no external credentials — so it is the
smallest possible thing that still exercises the module pipeline end to end
(manifest parse → env injection → recorded as active in `PROJECT.md`). Use it as
the copy-paste starting point for a real module.

Try it:

```bash
./scripts/new-project.sh --name demo --base nextjs-app --db none \
  --subdomain demo --modules hello-module
# -> services/demo/ is scaffolded; hello-module is composed in (its HELLO_MODULE_*
#    env templates are appended) and listed under "Active modules" in PROJECT.md.
```

---

## First real module: `i18n-bilingual`

[`i18n-bilingual/`](i18n-bilingual/README.md) is the first **feature** module —
the worked example of everything beyond env injection. It exercises the `files:`
capability (it layers Next.js locale routes, message catalogues and a language
switcher onto the base), declares a narrowed `base_compatible` (`nextjs-app`,
`fullstack`; a `dotnet-api` base gets backend RESX guidance instead), needs **no
database and no external credentials**, and is composed automatically by every
preset that lists it. Copy its shape when building another in-app module.

---

## Second real module: `content-admin`

[`content-admin/`](content-admin/README.md) is the worked example of a module
that ships a **service** — it stands up [Directus](https://directus.io), a
headless CMS, plus its own private database. It exercises the parts
`i18n-bilingual` did not:

- `compose: service.compose.yml` — a real container (the CMS) **and** its own
  dedicated, isolated PostgreSQL, both `internal`-only with **no host ports**
  (mirroring the auth layer's private `keycloak-db`). The per-project volumes are
  namespaced with `__PROJECT_NAME__` so two projects never collide.
- `base_compatible: all` made safe by **per-base `files/` subtrees** — a Next.js
  fetch wrapper for `nextjs-app` and the `fullstack` frontend, a .NET `HttpClient`
  helper for `dotnet-api` and the `fullstack` backend — so every base gets the
  right client and none falls back to the wrong one.
- `external_credentials: none` — the CMS admin user is created from env vars on
  first boot; `caddy_routes: none` because it is internal-only (the `/admin` UI is
  reached over an SSH tunnel via a commented bootstrap port).

Copy its shape when building a module that runs its own service.

---

## Third real module: `bookings`

[`bookings/`](bookings/README.md) is the worked example of an **in-app module
that uses the project's own database**. It adds an appointment / reservation
system — services, available time slots, and bookings with a
`pending → confirmed → cancelled` lifecycle — needed by the `clinic` and
`real-estate` presets. It exercises parts neither earlier module did:

- `files:` that layer **both backend and frontend** code at once — a small .NET
  bookings API (endpoints + repository + a startup migrator) **and** a bilingual
  Next.js booking UI — with per-base subtrees (`dotnet-api` = API only,
  `fullstack` = API + UI, `nextjs-app` = UI only).
- `database: postgres` with **`compose: none`** — it reuses the **project's own**
  PostgreSQL via `ConnectionStrings__Default` (by service name, no secrets, no
  dedicated container) and applies **idempotent SQL migrations** on startup. For
  `--db mysql`/`mongo`/`none` it degrades gracefully (documented fallback).
- **Double-booking prevented server-side** — a row-locked capacity check in the
  repository plus a partial unique index in the schema (not just UI validation).
- It may **replace** a base file when it must (the backend `Program.cs` /
  `app.csproj`, to wire the API + add the Npgsql dependency) while keeping
  everything else additive, so it still composes cleanly with `i18n-bilingual`
  and `content-admin`. It also shows how to **cooperate with i18n** without
  depending on it (a self-contained bilingual UI shipped at both `/booking` and
  `/<locale>/booking`).

Copy its shape when building an in-app feature backed by the project's database.

---

## Fourth real module: `auth-sso`

[`auth-sso/`](auth-sso/README.md) is the worked example of an **optional**
module that **integrates an existing platform service** (Keycloak) rather than
shipping its own. It puts a project behind single sign-on with **real OIDC** — the
Authorization Code flow with **PKCE** on the Next.js frontend, and **JWT bearer
validation** (issuer + audience + JWKS) on the .NET backend. It exercises parts the
earlier modules did not:

- **`compose:` as a per-base directory** (`compose: compose`) — three fragments
  (`compose/<base>.compose.yml`) that **merge OIDC env into the project's existing
  service(s)** (whose names differ by base), adding **no container and no host
  ports** (contrast `content-admin`, which ships its own container). The
  redirect / post-logout URLs are **derived from the project's subdomain**.
- **Additive .NET integration that composes with `bookings`.** `bookings` owns the
  backend `Program.cs` / `app.csproj`; auth-sso must not fight it. So the .NET half
  is an `[assembly: HostingStartup]` (`Auth/OidcHostingStartup.cs`, activated by an
  env flag) plus a `Directory.Build.props` (adds the JwtBearer package via MSBuild
  auto-import) — **no base-file replacement**. A `clinic` composes both modules
  with zero file collisions.
- **Cooperation with `i18n-bilingual` without a middleware clash** — protection is
  a **server-side guard in the route segment's layout** (not middleware, which
  i18n owns), and the protected page ships at both `/account` and
  `/<locale>/account`.
- **`external_credentials: none`** in the third-party sense (it uses the platform's
  own Keycloak), with the one-time, operator-run **Keycloak client creation**
  documented in [`auth-sso/SETUP.md`](auth-sso/SETUP.md) and deferred to the final
  manual session. **Optional, never forced:** presets add it only to admin contexts
  (`clinic`, `real-estate`); a public site (`company-site`) omits it.

Copy its shape when building a module that wires an existing platform service into
a project, or that must layer onto the base **additively** alongside another module
that owns a shared file.

---

## Fifth real module: `whatsapp-integration`

[`whatsapp-integration/`](whatsapp-integration/README.md) is the first module that
needs **external credentials** to go live — and the worked example of the
**swappable-provider** pattern that makes such a module **buildable and testable now,
with no external account**:

- **One interface, two providers.** `IWhatsappSender` (and a JS `getSender()`) with
  a **mock** implementation (the **default** — it logs the message and returns
  success) and a real **WhatsApp Cloud API (Meta)** implementation, fully coded. The
  live provider is chosen **once at start-up** from `WHATSAPP_PROVIDER`; flipping
  **mock → live** is a pure env change, so the whole flow runs today and only the
  final, deferred Meta onboarding (see its `SETUP.md`) stands between mock and live.
- **`external_credentials: required`** (documented), but `database: none` — sending
  is stateless. The real provider is **inert** until its phone-number-id +
  access-token are present.
- **Additive .NET** (a `Whatsapp/WhatsappHostingStartup.cs` `[assembly:HostingStartup]`,
  no NuGet, no `Program.cs`/`app.csproj` edit) so it composes with `bookings`,
  `auth-sso` and `local-payments`. It cooperates with `bookings` via a
  plain-argument helper (`SendBookingConfirmationAsync`) that needs no bookings type.

Copy its shape when building any module that talks to a **third-party API** —
provide a mock so the platform stays testable before credentials exist.

---

## Sixth real module: `local-payments`

[`local-payments/`](local-payments/README.md) is the worked example of a
**credentialed module with a stateful, idempotent lifecycle** built on the same
swappable-provider pattern:

- **One interface, two providers.** `IPaymentProvider` with a **mock** that
  simulates the **entire lifecycle locally** (create → "pay" → an **HMAC-signed
  webhook** → mark paid → status) and a real **Moyasar** (Saudi market: mada / Apple
  Pay / cards) provider, fully coded. Chosen once from `PAYMENTS_PROVIDER`; the real
  provider is **inert** until its API key is set.
- **`database: postgres`** — it records intents/status in the **project's own**
  database and recording is **idempotent** (row-locked `pending → paid` at most once;
  replayed webhooks are no-ops — **no double-credit**). Falls back gracefully on
  `--db mysql|mongo|none`.
- **Webhook signature verification is mandatory** and provider-specific (mock:
  `HMAC-SHA256`; Moyasar: its `secret_token`), always constant-time.
- **Additive .NET** (a `Payments/PaymentsHostingStartup.cs` `[assembly:HostingStartup]`
  + a **conditional** `Directory.Build.targets` that adds Npgsql only when `bookings`
  has not already) so it composes with every other module without a file collision.

Copy its shape when building a credentialed feature that must **persist state and
process verified callbacks idempotently**.

---

## Seventh real module: `web-analytics`

[`web-analytics/`](web-analytics/README.md) is the worked example of a **frontend-only
module that integrates a platform service WITHOUT shipping or replacing the root
layout** — and the platform's privacy answer to Google Analytics. It injects a
**self-hosted, privacy-first tracking snippet** ([Umami](https://umami.is)) so the
operator can see, for sites they own, who visits, what they view, where they came
from and what they click — with **no third-party tracker** and **no external
account**. It exercises parts the earlier modules did not:

- **Cooperative global injection via a root `app/template.jsx`.** A template **nests
  inside** the root layout, so the snippet covers every page **without replacing**
  the base's single-locale layout *or* `i18n-bilingual`'s per-request
  `<html lang dir>` layout — neither is touched, and `auth-sso`'s `/account` segment
  layout still nests underneath. This is the contrast with `i18n-bilingual` (which
  *replaces* the root layout) and `content-admin` (which ships its own container).
- **`external_credentials: none`, `database: none`.** It reports to the platform's
  own [analytics service](../../services/analytics/analytics.compose.yml) (Umami +
  its isolated DB, profile-gated); the module itself stores nothing and needs no
  account.
- **Strictly env-gated.** A server-component `Analytics.jsx` emits the tracker only
  when `ANALYTICS_SCRIPT_URL` + `ANALYTICS_SITE_ID` are set; otherwise it renders
  `null` — a project is unaffected until you opt in. A `compose:` per-base directory
  merges those two vars into the existing **web** service (no container, no host
  ports), and a `trackEvent` helper plus `data-umami-event` attributes record custom
  clicks/conversions.
- **`base_compatible: nextjs-app, fullstack`** (a `dotnet-api` base has no frontend
  to inject into — its README documents the manual server-side `<script>` include).
  **Optional, never forced:** presets add it where it helps (`company-site`,
  `ecommerce`); add it anywhere with `--modules web-analytics`. The operator's **own
  portfolio** is its primary first use.

Copy its shape when building a frontend module that must inject something **app-wide**
while leaving the base/i18n/auth layouts untouched.

---

## Eighth real module: `seo-toolkit`

[`seo-toolkit/`](seo-toolkit/README.md) is the worked example of a **strictly
additive, bilingual-aware** module — and the generated-site half of the platform's
**SEO & site-quality** capability (its other half is the
[SEO auditor](../../services/seo/README.md), `services/seo` + `scripts/seo.sh`). It
gives a site the on-page SEO defaults the auditor looks for: per-page **meta tags +
Open Graph/Twitter**, a **bilingual `sitemap.xml`** and **`robots.txt`**, and
**JSON-LD** structured-data scaffolding. It exercises a combination none of the
earlier modules did:

- **Strictly additive — zero file collisions.** Every file it ships is **new**
  (`app/sitemap.js`, `app/robots.js`, `lib/seo/*`, `components/StructuredData.jsx`);
  it **replaces no layout, page or template**. That is the deliberate contrast with
  `web-analytics` (which ships a root `template.jsx`) — shipping a second
  `template.jsx` would collide, so `seo-toolkit` instead exposes a `buildMetadata`
  helper + an opt-in `StructuredData` component you wire into pages you own. The
  result composes cleanly with `i18n-bilingual`, `auth-sso` **and** `web-analytics`.
- **Cooperates with `i18n-bilingual` without importing it.** Locales come from
  `SEO_LOCALES` (default `ar,en`) + `NEXT_PUBLIC_DEFAULT_LOCALE`; a localized site
  gets per-locale sitemap entries with **`hreflang`** alternates and locale-prefixed
  canonicals, a single-locale site gets one un-prefixed set. `/sitemap.xml` and
  `/robots.txt` are already in i18n's middleware skip-list, and `robots.txt`
  disallows the `auth-sso` `/account` area — so it lines up with both modules.
- **`compose:` per-base env-merge** (like `web-analytics`): merges `SEO_SITE_URL` /
  `SEO_SITE_NAME` / `SEO_LOCALES` into the existing web service (no new container, no
  host ports), with a per-project `__ENVPREFIX__SEO_SITE_URL` override.
- **`external_credentials: none`, `database: none`.** The on-page defaults need no
  account; the OPTIONAL AI is a property of the **audit engine**, not the site.
  **`base_compatible: nextjs-app, fullstack`** (a `dotnet-api` base gets documented
  server-side guidance). **Optional, never forced:** presets add it where it helps
  (`company-site`, `ecommerce`, `real-estate`); add it anywhere with
  `--modules seo-toolkit`.

Copy its shape when building a module that must layer **purely additive** assets
that cooperate with several other modules at once without owning any shared file.

---

## Planned modules

**None.** All declared feature modules have been implemented (the two credentialed
ones — `whatsapp-integration`, `local-payments` — ship with a working mock so they
build and run before their external accounts exist). The mechanism remains: a future
module declared with `status: planned` is skipped **gracefully** and recorded as a
TODO in the generated project's `PROJECT.md` (with any external-credential note), so
a project is never left broken. See *How to add a new module* below.

---

## How to add a new module

1. Copy `hello-module/` to `templates/modules/<your-module>/`.
2. Edit `module.manifest`: set `name`, `description`, `status: implemented`, the
   compatible base shapes (`base_compatible`), the DB engine, any
   `external_credentials`, the `env` list, and whether you ship a `files:` tree, a
   `compose:` fragment and/or a `caddy_routes:` file.
3. If it adds **in-app code** (pages, components, config), put it under `files/`
   (or `files/<base>/` for base-specific layouts) using the same placeholders as
   the base; the generator copies and substitutes it into the project.
4. If it runs a service, add a `service.compose.yml` fragment that obeys the hard
   rules (ARM64, pinned tag, no host ports, mem limit, `no-new-privileges`,
   `internal`/`proxy` networks). Use `__PROJECT_NAME__` so the service name is
   namespaced per project (e.g. `__PROJECT_NAME__-<module>`).
5. If it exposes HTTP, add a `caddy.snippet` with path routes under the project's
   subdomain (no new host ports).
6. List its env vars in `env:` and mirror them (empty) in `env.example`.
7. Done — `./scripts/new-project.sh ... --modules <your-module>` now composes it
   in, and any preset that lists it stops being a TODO automatically.

## Promoting a planned module to implemented

Turning a `planned` row into a real module (as `i18n-bilingual` was) is a small,
repeatable promotion:

1. **Build the module folder** following *How to add a new module* above — the
   manifest's `status: implemented` is what the generator keys off (it discovers
   implemented modules by scanning `templates/modules/*/module.manifest`).
2. **Pick the right contribution** for what the feature is:
   - in-app feature (i18n, a UI widget) → ship a `files:` tree;
   - a separate service (a worker, an admin app) → ship a `compose:` fragment
     (and a `caddy_routes:` snippet if it serves HTTP);
   - both, if needed. Set `database:` / `external_credentials:` honestly.
3. **Drop it from the planned list** in `scripts/new-project.sh` (the
   `PLANNED_MODULES` string and the `PLANNED_DESC` map) and from the *Planned
   modules* table above.
4. **Nothing else changes for presets.** Any preset that already lists the module
   stops recording it as a TODO and starts composing it automatically — re-run the
   generator and it is now *Active*.

See [`i18n-bilingual/README.md`](i18n-bilingual/README.md) for a fully worked
example of this promotion.
