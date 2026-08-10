# The pi-system template system

This directory documents the **three-layer template system** that the project
generator ([`scripts/new-project.sh`](../../scripts/new-project.sh)) builds on.
It is the single place to understand *how the layers fit together* and *how to
extend them*. Layer-specific contracts live next to the code they govern:

- **Base** — [`templates/base/README.md`](../base/README.md)
- **Modules** — [`templates/modules/README.md`](../modules/README.md) (module contract)
- **Presets** — [`templates/presets/README.md`](../presets/README.md) (preset contract)

---

## The three-layer philosophy

The goal is **low-maintenance variety**: stand up many different client sites
(clinics, shops, company sites, listings…) without re-inventing each one, and
without a sprawl of one-off codebases to maintain. We get there by separating
*what every project shares* from *what varies*, in three layers:

```
            ┌──────────────────────────────────────────────┐
 presets    │  sector recipe: pick ONE base + a MODULE set  │   clinic, ecommerce,
            │  (clinic, ecommerce, company-site, …)         │   company-site, real-estate
            └───────────────────────┬──────────────────────┘
                                    │ composes
            ┌───────────────────────▼──────────────────────┐
 modules    │  composable FEATURES layered on a base        │   bookings, content-admin,
            │  (bookings, i18n, payments, …)                │   i18n-bilingual, payments, …
            └───────────────────────┬──────────────────────┘
                                    │ layered on
            ┌───────────────────────▼──────────────────────┐
 base       │  the shared SCAFFOLD every project starts from │   dotnet-api, nextjs-app,
            │  (Dockerfile, /health, compose fragment, …)   │   fullstack
            └──────────────────────────────────────────────┘
```

- **Base — inherited by all.** The three scaffolds (`dotnet-api`, `nextjs-app`,
  `fullstack`) are the foundation. They carry the platform's hard rules (ARM64,
  pinned tags, non-root, `/health`, no host ports, mem limits) and cross-cutting
  conventions (e.g. [bilingual/RTL](#bilingual--rtl-a-base-convention)) so every
  project gets them for free. Fix something here → every future project benefits.
- **Modules — composed on top.** A feature you build **once** and reuse: a
  booking system, a content admin, local payments. A module declares what it
  needs (env, compose, Caddy routes, DB, external credentials) in a manifest and
  is composed into any compatible base. This is where variety comes from without
  duplication.
- **Presets — sector recipes.** A preset is just a declaration: *"a clinic is a
  `fullstack` base + `bookings` + `content-admin` + `i18n-bilingual` + `auth-sso` +
  `whatsapp-integration`."* Pick a preset and the generator assembles the whole
  thing in one command.

Why this keeps maintenance low: shared behaviour lives in exactly one place per
layer. A base change lands everywhere; a module improvement lands in every
project that composes it; a sector tweak is a one-line preset edit. New client of
an existing sector = one command, no new code.

> **Current state.** The base layer is real and working. The module layer ships
> its **contract**, the `hello-module` reference, and **six real feature
> modules** — [`i18n-bilingual`](../modules/i18n-bilingual/README.md) (Arabic/
> English + RTL), [`content-admin`](../modules/content-admin/README.md) (a Directus
> headless CMS), [`bookings`](../modules/bookings/README.md) (appointment /
> reservation scheduling), [`auth-sso`](../modules/auth-sso/README.md) (optional
> Keycloak SSO / OIDC),
> [`whatsapp-integration`](../modules/whatsapp-integration/README.md) (WhatsApp
> messaging) and [`local-payments`](../modules/local-payments/README.md) (mada /
> card checkout). **No feature modules remain planned.** The last two need
> **external credentials** to go *live*, but each ships a working **mock / sandbox
> provider** chosen by an env flag, so they compose and run **now** with no external
> account (flipping to live is a one-time env change — see their `SETUP.md`). The
> preset layer ships its **contract** plus **four `status: available` stubs**
> (`clinic` / `real-estate` compose the admin set including SSO; `ecommerce` adds
> payments + WhatsApp; `company-site` stays a clean public site). The generator
> understands all three layers: it composes implemented modules (honouring each
> module's `base_compatible`), and **skips any planned/incompatible ones gracefully**,
> recording them in each project's `PROJECT.md` so nothing is ever generated broken.

---

## How the generator uses the layers

```bash
# From a preset (it declares base, db, locale and the module list):
./scripts/new-project.sh --name happy-teeth --preset clinic --subdomain teeth

# Or manually: a base shape + an explicit module list:
./scripts/new-project.sh --name acme --base fullstack --db postgres \
  --subdomain acme --locale ar --modules hello-module
```

One pass:

1. **Resolve inputs.** A `--preset` supplies the base shape, DB, default locale
   and module list; any of `--db` / `--locale` / `--subdomain` overrides it, and
   `--modules` are added on top. Manual mode takes `--base` (+ optional
   `--modules`) instead. Everything is validated (name, base, db, locale,
   subdomain, module names).
2. **Stamp the base.** Copies `templates/base/<shape>` → `services/<name>/` and
   substitutes the placeholders (incl. `__DEFAULT_LOCALE__` / `__DEFAULT_DIR__`).
3. **Compose modules.** For each requested module: if **implemented** and
   compatible with the chosen base, wire it in (append its env templates, copy its
   `files:` tree into the project, copy its compose fragment as
   `services/<name>/<name>.<module>.compose.yml`, inject its Caddy routes, list it
   as *active*); if **planned**, skip it and record a TODO; if **implemented but
   incompatible with this base**, skip it and record it under *Modules not applied*
   (with a pointer to the module's alternative, e.g. backend guidance). The project
   is never left broken.
4. **Wire the platform.** Append an env-driven Caddy site block, an empty
   per-project `.env.example` section, and write `services/<name>/PROJECT.md`
   (summary + active modules + planned-module TODOs, flagging any that need
   external credentials).
5. **Validate** the merged compose (base + module fragments) when Docker + `.env`
   are present, and print the next steps.

`./scripts/project.sh up <name>` then runs the base compose together with the
project's main fragment **and** any module fragments
(`services/<name>/<name>.*.compose.yml`).

---

## Bilingual / RTL — a base convention

This platform is **Arabic-first, English-second**, so bilingual + RTL readiness
is a **base concern**, not a per-project afterthought. The base provides the
*convention and the plug-in point*; the heavy lifting now lives in the
**implemented** [`i18n-bilingual`](../modules/i18n-bilingual/README.md) module.

- `--locale ar|en` (or a preset's `default_locale`) sets `__DEFAULT_LOCALE__`;
  the generator derives `__DEFAULT_DIR__` (`ar→rtl`, `en→ltr`).
- Next.js root layouts render `<html lang="<locale>" dir="<dir>">`, so an Arabic
  project is right-to-left out of the box.
- Every base service gets a `DEFAULT_LOCALE` env var (Next.js also
  `NEXT_PUBLIC_DEFAULT_LOCALE`) — the hook the `i18n-bilingual` module reads.
- Add `--modules i18n-bilingual` (or use any preset — all four list it) and the
  generator layers in **live language switching, message catalogues and
  locale-prefixed routes** (`/ar`, `/en`) via its `files:` tree, replacing the
  base's single-locale layout with a per-request, RTL-correct one.

See [`templates/base/README.md`](../base/README.md#bilingual-readiness-arabic--english--rtl--a-base-concern)
for the full convention (including the CSS *logical properties* tip).

---

## How to add a module

Full contract: [`templates/modules/README.md`](../modules/README.md). In short:

1. Copy `templates/modules/hello-module/` → `templates/modules/<your-module>/`.
2. Edit `module.manifest`: `name`, `description`, `status: implemented`,
   `base_compatible`, `database`, `external_credentials`, the `env` list, and
   whether you ship a `files:` tree, a `compose:` fragment and/or `caddy_routes:`.
3. Add the assets you declared: a `files/` tree (in-app source, optionally
   `files/<base>/` per base); a `service.compose.yml` that obeys the hard rules; a
   `caddy.snippet` with path routes; mirror env names in `env.example`.
4. `./scripts/new-project.sh ... --modules <your-module>` now composes it in, and
   any preset that lists it stops being a TODO automatically.

> **Promoting a planned module → implemented** (as `i18n-bilingual`,
> `content-admin` and `bookings` were): build the folder, set `status:
> implemented`, choose its contribution (`files:` for an in-app feature,
> `compose:`/`caddy_routes:` for a service — or **both**), and remove it from the
> `PLANNED_MODULES`/`PLANNED_DESC` list in `scripts/new-project.sh`. Presets need
> **no change** — they compose it automatically on the next run. See the
> [module contract](../modules/README.md#promoting-a-planned-module-to-implemented).
>
> **Lessons from the promotions.**
> - `i18n-bilingual` showed a pure **in-app** module (`files:` only, a narrowed
>   `base_compatible`, no service).
> - `content-admin` showed a module that ships **both** a `compose:` service (the
>   Directus CMS + its own private DB, internal-only, no host ports) **and**
>   per-base `files:` clients, while being `base_compatible: all`. The trick that
>   makes "all" safe: give **every** base its own `files/<base>/` subtree (Next.js
>   wrapper for the JS bases, a .NET helper for the API bases) so no base falls
>   back to the wrong client. It also confirmed the convention for an
>   **internal-only admin UI**: no host ports / no `proxy`, reached via the
>   commented bootstrap port + an SSH tunnel (as the management UIs do).
> - `bookings` showed an in-app module that uses the **project's own database**:
>   `database: postgres` with **`compose: none`** (no dedicated container), reached
>   by service name via `ConnectionStrings__Default`, with **idempotent SQL
>   migrations** applied by the existing backend on startup. Its `files:` layer
>   **both backend and frontend** at once and may **replace** a base file when
>   required (the backend `Program.cs` / `app.csproj`) while keeping everything
>   else additive, so it still composes with the other two modules. It also models
>   "**cooperate with i18n if present**" — a self-contained bilingual UI shipped at
>   both `/booking` and `/<locale>/booking` (no broken reference either way) — and
>   **server-side conflict prevention** (a row-locked capacity check + a partial
>   unique index), not UI-only validation.
> - `auth-sso` showed an **optional** module that **integrates an existing platform
>   service** (Keycloak) with **real OIDC** — Authorization Code + PKCE on the
>   frontend, JWT bearer validation on the backend. It added the **per-base
>   `compose:` directory** convention (`compose: compose` → `compose/<base>.compose.yml`)
>   to **merge env into the base's own service(s)** (whose names differ by shape)
>   with no new container/ports, and it stays **fully additive on .NET**
>   (`[assembly: HostingStartup]` + `Directory.Build.props`, no `Program.cs` /
>   `app.csproj` replacement) so it composes with `bookings`, which owns those
>   files. Route protection is a **server-side layout guard** (not middleware, which
>   `i18n` owns). It is **never forced** — presets add it only to admin contexts.
> - `whatsapp-integration` and `local-payments` showed the **swappable-provider**
>   pattern for modules that need **external credentials**: one internal interface
>   (`IWhatsappSender` / `IPaymentProvider`) with a **mock/sandbox provider active by
>   default** (so the whole flow builds, runs and is testable with no account) and a
>   real provider (WhatsApp Cloud API / Moyasar) that is fully coded but **inert
>   until env credentials exist** — flipping mock→live is a pure env change. They
>   stay **additive on .NET** (`[assembly: HostingStartup]`), and `local-payments`
>   adds Npgsql via a **conditional `Directory.Build.targets`** (skipped when
>   `bookings` already references it; a different filename than auth-sso's `.props`)
>   so all the credentialed/DB modules compose together with no file or package
>   collision. `local-payments` also models **idempotent webhook recording** (no
>   double-credit) with **mandatory signature verification**.

## How to add a sector preset

Full contract: [`templates/presets/README.md`](../presets/README.md). In short:

1. Create `templates/presets/<sector>/preset.manifest`.
2. Set `name`, `description`, `base`, `database`, `default_locale`, and the
   `modules` list it composes (`status: planned` until those modules exist).
3. `./scripts/new-project.sh --preset <sector>` now works — composing whatever
   modules are implemented and recording the rest as TODOs.

---

## Directory layout

```
templates/
├── base/        the shared scaffolds every project starts from
│   ├── dotnet-api/      .NET Web API (multi-stage, ARM64)
│   ├── nextjs-app/      Next.js standalone app (multi-stage, ARM64)
│   ├── fullstack/       .NET backend (internal) + Next.js frontend (proxy)
│   └── README.md        base layer + bilingual/RTL convention + placeholders
├── modules/     composable features (contract + reference + six real modules)
│   ├── hello-module/         minimal, safe reference module (env templates only)
│   ├── i18n-bilingual/       first real module — Arabic/English + RTL (files: tree)
│   ├── content-admin/        second real module — Directus headless CMS (compose + files)
│   ├── bookings/             third real module — appointment scheduling (files: backend + frontend, uses the project DB)
│   ├── auth-sso/             fourth real module — optional Keycloak SSO/OIDC (per-base compose: env-merge + additive .NET)
│   ├── whatsapp-integration/ fifth real module — WhatsApp messaging (swappable provider: mock | Cloud API; needs creds to go live)
│   ├── local-payments/       sixth real module — mada/card checkout (swappable provider: mock | Moyasar; idempotent webhook; needs creds to go live)
│   └── README.md             the MODULE CONTRACT (all feature modules implemented)
├── presets/     sector recipes (contract + declaration-only stubs, status: available)
│   ├── clinic/          preset.manifest
│   ├── ecommerce/       preset.manifest
│   ├── company-site/    preset.manifest
│   ├── real-estate/     preset.manifest
│   └── README.md        the PRESET CONTRACT
└── docs/        this file — the three-layer philosophy + how to extend
```
