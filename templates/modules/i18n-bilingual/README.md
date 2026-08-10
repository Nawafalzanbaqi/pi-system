# i18n-bilingual — Arabic / English with RTL

The first **real** feature module. It turns a base Next.js app from *single-locale*
(the base only stamps `<html lang dir>` once, at scaffold time) into a genuinely
**bilingual** app: locale-prefixed routes (`/ar`, `/en`), per-request `<html lang
dir>` (RTL for Arabic, LTR for English), JSON message catalogues, and a language
switcher — with **no external credentials, no database, and no extra container**.

It plugs into the base's [bilingual convention](../../base/README.md#bilingual-readiness-arabic--english--rtl--a-base-concern):
the base provides `NEXT_PUBLIC_DEFAULT_LOCALE` / `__DEFAULT_DIR__`; this module
reads them and layers live switching on top.

## What it declares

See [`module.manifest`](module.manifest):

- `status: implemented` — the generator composes it in.
- `base_compatible: nextjs-app, fullstack` — it is an in-app **frontend** feature.
  On a pure `dotnet-api` base it is **not** composed; use the
  [backend guidance](#optional-backend-net-localization) below instead.
- `database: none`, `external_credentials: none`, `compose: none`,
  `caddy_routes: none` — nothing to stand up, no proxy changes.
- `files: files` — the **source files** it layers onto the project (this is what
  makes it an in-app module). See [how the generator wires it](#how-the-generator-wires-it).
- `env: SUPPORTED_LOCALES` — one **optional** template (default `ar,en`); the
  module works with zero config.

## How the generator wires it

When a project on a compatible base requests `i18n-bilingual`, the generator
(`scripts/new-project.sh`):

1. **Files.** Copies this module's `files/<base>/` tree into the project,
   substituting the usual placeholders (`__PROJECT_NAME__`, `__DEFAULT_LOCALE__`,
   …). A base-specific subtree overrides the generic one, so each base gets the
   code at the right path:
   - `nextjs-app` → files land at the app root (`services/<name>/…`).
   - `fullstack` → files land under the frontend (`services/<name>/frontend/…`).
2. **Env.** Appends `SUPPORTED_LOCALES=` (blank) to the project's `.env.example`
   section, labelled `(module: i18n-bilingual)`.
3. **Record.** Lists `i18n-bilingual` under **Active modules** in `PROJECT.md`.

No compose fragment and no Caddy routes — locale handling is entirely in-app.

### What gets added to the project

```
middleware.js                  # redirect "/" → "/<locale>"; forward x-pi-locale header
i18n/
  config.js                    # locales, defaultLocale, dir(), isLocale(), names
  dictionaries.js              # server-side getDictionary(locale) loader
locales/
  ar.json  en.json             # message catalogues (a few example keys)
components/
  LanguageSwitcher.jsx         # client switcher (swaps the /<locale> segment)
app/
  globals.css                  # RTL-aware base styles (logical properties)
  layout.jsx                   # ROOT layout: <html lang dir> from the middleware header
  page.jsx                     # "/" → redirect to default locale (defensive)
  [locale]/
    layout.jsx                 # validates the locale; generateStaticParams for ar/en
    page.jsx                   # localized home (dictionary + switcher)
```

> The module **replaces** the base's single-locale `app/layout.jsx` and
> `app/page.jsx` with locale-aware versions; the base's `app/health/route.js`
> is untouched (the middleware skips `/health`).

### How locale selection works

- **Routing.** Every page lives under `app/[locale]/…`. `middleware.js` redirects
  an un-prefixed path to `"/<locale>"`, choosing the locale from the visitor's
  cookie → `Accept-Language` → the scaffold default (`__DEFAULT_LOCALE__`).
- **Direction.** For prefixed paths the middleware forwards the active locale in
  the `x-pi-locale` request header; the **root layout** reads it and renders
  `<html lang="<locale>" dir="<rtl|ltr>">` on the server — no flash.
- **Switching.** `LanguageSwitcher` swaps the leading `/<locale>` segment and
  stores the choice in the `pi_locale` cookie so it persists.

## Run it

```bash
# Composed automatically by any preset that lists it (clinic, ecommerce,
# company-site, real-estate), or add it explicitly:
./scripts/new-project.sh --name demo-site --base nextjs-app --db none \
  --subdomain demo --modules i18n-bilingual --locale ar

cd services/demo-site
npm install
npm run dev        # http://localhost:3000  → redirects to /ar (RTL)
                   # http://localhost:3000/en → English (LTR)
```

`--locale ar` makes Arabic the default (RTL); `--locale en` makes English the
default (LTR). Both locales are always reachable via their prefix and the switcher.

## Add a new translation key

1. Add the key to **every** dictionary: `locales/ar.json` **and** `locales/en.json`
   (keep the key sets in sync).
2. Use it in a Server Component:
   ```jsx
   import { getDictionary } from '../../i18n/dictionaries';
   const t = await getDictionary(locale);
   return <h2>{t.myNewKey}</h2>;
   ```

## Add another locale (e.g. French)

1. `locales/fr.json` — copy `en.json` and translate.
2. `i18n/config.js` — add `'fr'` to `locales`, a name to `localeNames`, and add it
   to `RTL_LOCALES` only if it is right-to-left.
3. `i18n/dictionaries.js` — add `fr: () => import('../locales/fr.json')…`.

(The module is named *bilingual* because the platform's sectors target ar/en;
the code itself generalizes to N locales.)

## RTL conventions

`dir` is set on `<html>`, so the whole document mirrors. To keep components
direction-correct **without** writing locale-specific CSS:

- Prefer **logical** CSS properties — `margin-inline-start`, `padding-inline`,
  `inset-inline-end`, `border-block-end` — over physical `left`/`right`. See
  `app/globals.css` for worked examples.
- Use `text-align: start` / `end` (not `left`/`right`).
- For icons that imply direction (arrows, chevrons), flip them with
  `[dir="rtl"] .chevron { transform: scaleX(-1); }`.
- Numbers and Latin snippets inside Arabic text render fine; wrap forced-LTR runs
  (URLs, code) with `<span dir="ltr">…</span>` when needed.

## Optional: backend (.NET) localization

This module does not touch the backend, but a `fullstack` API (or a `dotnet-api`
service) can localize its own responses with ASP.NET Core request localization
keyed off `Accept-Language` (or a locale claim). It needs **no new packages** —
it is built into the framework. Add to `Program.cs`:

```csharp
var supportedCultures = new[] { "ar", "en" };

var app = builder.Build();

app.UseRequestLocalization(new RequestLocalizationOptions()
    .SetDefaultCulture("ar")                 // matches the platform default (RTL)
    .AddSupportedCultures(supportedCultures)
    .AddSupportedUICultures(supportedCultures));
// Order of providers: query (?culture=ar) → cookie → Accept-Language (defaults).
```

Then key messages off resource files (`.resx`):

- `Resources/Messages.resx` (default/Arabic) and `Resources/Messages.en.resx`.
- Register the localizer service:
  ```csharp
  builder.Services.AddLocalization(o => o.ResourcesPath = "Resources");
  ```
- Resolve strings via the injected `IStringLocalizer<T>`:
  ```csharp
  app.MapGet("/api/greeting", (IStringLocalizer<Program> L) =>
      Results.Ok(new { message = L["Greeting"].Value }));
  ```

`CultureInfo.CurrentUICulture.TextInfo.IsRightToLeft` gives the direction
server-side if an API ever needs to return it. The frontend module remains the
source of truth for UI direction.

## Turning a planned module into an implemented one

This module is the worked example of that promotion — see the short note in
[`../README.md`](../README.md#promoting-a-planned-module-to-implemented).
