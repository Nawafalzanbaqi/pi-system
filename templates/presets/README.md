# Presets layer — sector recipes

A **preset** is a sector recipe: it names **one [base](../base/README.md) shape**
and the set of [modules](../modules/README.md) that, composed together, make a
ready-to-run app for a particular kind of business — a clinic, an online store, a
company site, a real-estate listing site. Presets are the highest layer: pick a
preset and the generator stamps the base and composes every module the sector
needs, in one command.

> **Status of this layer.** These are **declaration-only stubs**. There is **no
> sector app code here** — a preset is just a `preset.manifest` that *declares*
> the shape + module list. **All seven** feature modules are now **implemented** —
> [`i18n-bilingual`](../modules/README.md#first-real-module-i18n-bilingual),
> [`content-admin`](../modules/README.md#second-real-module-content-admin),
> [`bookings`](../modules/README.md#third-real-module-bookings),
> [`auth-sso`](../modules/README.md#fourth-real-module-auth-sso),
> [`whatsapp-integration`](../modules/README.md#fifth-real-module-whatsapp-integration),
> [`local-payments`](../modules/README.md#sixth-real-module-local-payments),
> [`web-analytics`](../modules/README.md#seventh-real-module-web-analytics)
> and [`seo-toolkit`](../modules/README.md#eighth-real-module-seo-toolkit) — so
> every preset composes its **entire** module list **automatically**: generated
> projects are bilingual (Arabic/English + RTL), content-managed, have a working
> booking system (for `clinic` / `real-estate`), WhatsApp messaging, (for
> `ecommerce`) a payment checkout, privacy-first self-hosted web analytics and
> on-page SEO defaults (for `company-site` / `ecommerce` / `real-estate`) — all
> working **out of the box**. The two
> credentialed modules (`whatsapp-integration`, `local-payments`) run on a **mock /
> sandbox provider by default**, so there are **no remaining TODOs**: going *live*
> with WhatsApp / payments is a one-time env change (each module's `SETUP.md`), not
> a code gap. `auth-sso`, `web-analytics` and `seo-toolkit` are **optional**: each is
> added only where it belongs (a public marketing site omits `auth-sso`;
> `web-analytics` is opt-in via `.env`; `seo-toolkit` needs no credentials), and any
> is easily dropped from a preset's list.

---

## The preset contract (`preset.manifest`)

Every preset is a folder under `templates/presets/<preset-name>/` containing a
single **`preset.manifest`** file — the same simple, line-based `key: value`
format as modules (parsed with plain shell, no YAML). Keys:

| Key              | Required | Meaning                                                                                              |
| ---------------- | -------- | ---------------------------------------------------------------------------------------------------- |
| `name`           | yes      | The preset's identifier (must equal the folder name; `^[a-z][a-z0-9-]*$`).                            |
| `description`    | yes      | One line describing the sector this preset targets.                                                  |
| `status`         | yes      | `planned` while its modules are unbuilt; becomes `available` once they exist (informational).         |
| `base`           | yes      | The base shape it uses: `dotnet-api` \| `nextjs-app` \| `fullstack`.                                  |
| `database`       | yes      | Default DB engine: `postgres` \| `mysql` \| `mongo` \| `none` (overridable with `--db`).              |
| `default_locale` | yes      | Default locale `ar` \| `en` (overridable with `--locale`). Drives RTL/LTR — see the base convention. |
| `modules`        | yes      | Comma-separated module list this preset composes (in order).                                          |

A preset declares **what to compose**; it does not contain app code. The
generator resolves the module list against the modules layer at scaffold time:
implemented modules are composed in, planned ones are recorded as TODOs.

### How a preset is used

```bash
# Everything from the preset (base shape, db, locale, module list):
./scripts/new-project.sh --name happy-teeth --preset clinic --subdomain teeth

# Override the preset's defaults, and add an extra module on top:
./scripts/new-project.sh --name happy-teeth --preset clinic --subdomain teeth \
  --db postgres --locale ar --modules hello-module
```

`--db`, `--locale` and `--subdomain` override the preset's declared defaults;
`--modules` are **added** to the preset's list (deduplicated). `--name` and
`--subdomain` are always project-specific.

---

## The sector stubs

All four are now `status: available` (every module they list is implemented) and
default to **Arabic** (`default_locale: ar`, so RTL) for the platform's primary
market. Every module below is **implemented and composed today** — the two
credentialed ones run on a **mock provider by default**.

| Preset         | Base         | DB       | Composes (all implemented)                                               |
| -------------- | ------------ | -------- | ------------------------------------------------------------------------ |
| [`clinic`](clinic/preset.manifest)             | `fullstack`  | postgres | `bookings`, `content-admin`, `i18n-bilingual`, `auth-sso`, `whatsapp-integration` |
| [`ecommerce`](ecommerce/preset.manifest)       | `fullstack`  | postgres | `local-payments`, `content-admin`, `i18n-bilingual`, `whatsapp-integration`, `web-analytics`, `seo-toolkit` |
| [`company-site`](company-site/preset.manifest) | `nextjs-app` | postgres | `content-admin`, `i18n-bilingual`, `web-analytics`, `seo-toolkit` _(no `auth-sso` — public site)_ |
| [`real-estate`](real-estate/preset.manifest)   | `fullstack`  | postgres | `bookings`, `content-admin`, `i18n-bilingual`, `auth-sso`, `whatsapp-integration`, `seo-toolkit` |

> `whatsapp-integration` (in `clinic` / `ecommerce` / `real-estate`) and
> `local-payments` (in `ecommerce`) compose and run **immediately on their mock
> providers** — no external account is needed to build, deploy or demo the project.
> Going **live** with real WhatsApp messaging or real payments (mada / Apple Pay /
> cards) needs **external merchant / business credentials** — a one-time,
> operator-run step documented in each module's `SETUP.md`. `company-site` stays
> clean (no credentialed modules).
>
> `web-analytics` (in `company-site` / `ecommerce`) needs **no external account** —
> it is privacy-first and **self-hosted**. It is **opt-in**: the tracker stays off
> until you set `ANALYTICS_*` in `.env` and bring up the platform analytics service
> (`./scripts/analytics.sh up`). Add it to any other preset/project with
> `--modules web-analytics`, or drop it from a list to opt a site out. The
> operator's **own portfolio** (a `company-site`) is its primary first use.
>
> `seo-toolkit` (in `company-site` / `ecommerce` / `real-estate`) needs **no
> external account** either — it adds on-page SEO defaults (meta + Open Graph, a
> bilingual `sitemap.xml` & `robots.txt`, JSON-LD) that cooperate with `i18n`. It is
> the generated-site companion to the **SEO auditor** (`services/seo` +
> `./scripts/seo.sh`), which audits the sites you own and recommends fixes (free and
> deterministic by default; an optional AI enrichment is off until you set a key).
> Add it anywhere with `--modules seo-toolkit`.

---

## How to add a new sector preset

1. Create `templates/presets/<your-sector>/preset.manifest`.
2. Fill in `name`, `description`, the `base` shape, the default `database` and
   `default_locale`, and the `modules` list it should compose.
3. Set `status: planned` if any listed module is still planned; flip to
   `available` once they're all implemented.
4. Done — `./scripts/new-project.sh --preset <your-sector>` now works, composing
   whatever modules are implemented and recording the rest as TODOs.
