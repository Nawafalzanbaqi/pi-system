# Base layer — the shared foundation

The **base** layer holds the three self-contained scaffolds that every pi-system
project starts from. They are the *foundation*: a project is one base shape, with
zero or more [modules](../modules/README.md) layered on top, optionally chosen
all at once through a sector [preset](../presets/README.md).

> These three scaffolds are the original, working templates — relocated here
> unchanged. The generator ([`scripts/new-project.sh`](../../scripts/new-project.sh))
> copies one of them into `services/<name>/` and substitutes the placeholders.

| Base shape   | Stack                                   | Web-facing service       | Typical use                               |
| ------------ | --------------------------------------- | ------------------------ | ----------------------------------------- |
| `dotnet-api` | .NET Web API (current LTS), minimal     | the API (`:8080`)        | a backend / JSON API                      |
| `nextjs-app` | Next.js (App Router, standalone output) | the app (`:3000`)        | a web frontend / SSR app                  |
| `fullstack`  | .NET API **+** Next.js                  | the frontend (`:3000`)   | a frontend that calls an internal API     |

Every base shape ships a **multi-stage Dockerfile** with pinned, ARM64-compatible
base images (.NET 10 LTS, Node 22 LTS — never `latest`), a small runtime image, a
non-root user, a `/health` endpoint, and a compose **fragment** with **no host
ports**, a memory limit, `restart: unless-stopped` and `no-new-privileges`. In
`fullstack`, the API is internal-only and the frontend reaches it server-side at
`http://<name>-api:8080`.

## Placeholders

The generator substitutes these tokens literally when it stamps out a project:

| Placeholder                | Becomes                                                        |
| -------------------------- | ------------------------------------------------------------- |
| `__PROJECT_NAME__`         | the project / service name                                    |
| `__SUBDOMAIN__`            | the Caddy subdomain                                           |
| `__DB_ENGINE__`            | `postgres` \| `mysql` \| `mongo` \| `none`                    |
| `__DB_HOST__` `__DB_PORT__`| DB service name + port on the `internal` network             |
| `__DB_CONNECTION_STRING__` | .NET connection string (built from shared `.env` DB creds)   |
| `__DB_URL__`               | URL-form connection string (e.g. for Next.js / Prisma)       |
| `__ENVPREFIX__`            | uppercased name + `_` (namespaces per-project `.env` vars)    |
| `__DEFAULT_LOCALE__`       | the default locale, `ar` or `en` (see below)                 |
| `__DEFAULT_DIR__`          | text direction derived from the locale: `rtl` (ar) / `ltr`   |
| `__GENERATED_DATE__`       | the scaffold date                                            |
| `__TEMPLATE__`             | the base shape it was generated from                        |

## Bilingual readiness (Arabic / English + RTL) — a base concern

This platform targets an **Arabic-first, English-second** audience, so
**bilingual + RTL readiness is built into the base**, not bolted on later. It is
intentionally a *convention plus a plug-in point* here — the heavy lifting (live
language switching, translated content) is the job of the now-implemented
[`i18n-bilingual`](../modules/i18n-bilingual/README.md) module.

What the base provides:

- **`__DEFAULT_LOCALE__` placeholder** — `ar` or `en`, chosen at scaffold time
  (`--locale`, or inherited from a preset; defaults to `ar`). The generator also
  derives **`__DEFAULT_DIR__`** from it: `ar → rtl`, `en → ltr`.
- **HTML lang + dir.** The Next.js root layouts render
  `<html lang="__DEFAULT_LOCALE__" dir="__DEFAULT_DIR__">`, so an Arabic project
  is right-to-left out of the box and an English one is left-to-right — correct
  document direction with zero extra work.
- **`DEFAULT_LOCALE` env var.** Every base service receives `DEFAULT_LOCALE`
  (Next.js also gets `NEXT_PUBLIC_DEFAULT_LOCALE` for the browser). This is the
  **plug-in point**: app code and the future `i18n-bilingual` module read it to
  decide the active language and load the matching message catalogue.

What the base deliberately does **not** do (left to the `i18n-bilingual` module):
ship translation catalogues, a language switcher, locale-prefixed routes
(`/ar`, `/en`), or per-request locale negotiation. The convention above is the
contract those features build on — so they arrive by **composing the module**
(which layers them in, replacing this single-locale layout in the generated
project), never by hand-editing the base templates.

> **RTL styling tip for app authors.** Because `dir` is set on `<html>`, prefer
> CSS *logical* properties (`margin-inline-start`, `padding-inline`, `inset-inline`)
> over physical ones (`margin-left`, …) so layouts mirror automatically between
> Arabic and English.

## Dependency security maintenance — a base concern

Pinned dependency versions live in the base (and in any module that ships its own
frontend, e.g. [`auth-sso`](../modules/auth-sso/README.md)). Because **every
generated project inherits these pins**, a security bump here is *base
maintenance that propagates to all future projects* — fix it once, in the
template, rather than in each generated copy.

| Dependency | Pin | Notes |
| ---------- | --- | ----- |
| Next.js    | **`15.5.18`** | Exact pin (never a range / `latest`). React stays at `19.0.0`, a supported peer for Next 15.5.x. |
| React / react-dom | `19.0.0` | Compatible with the Next.js pin above. |
| Node (runtime) | `node:22-alpine` | LTS, pinned in the Dockerfiles. |
| .NET | `10.0` LTS | Pinned in the `dotnet-api` / `fullstack` Dockerfiles. |

**Fixed: CVE-2025-66478** (Next.js App Router RSC remote-code-execution, the
downstream tracking of React's CVE-2025-55182). The base previously pinned
`next@15.1.0`, which is affected. It is now pinned to **`next@15.5.18`** — the
latest stable, secure 15.x release, which supersedes the `15.5.7` advisory patch
and rolls up the rest of the May 2026 security release. The bump touches versions
only; module behaviour is unchanged, and both base shapes that ship a frontend
(`nextjs-app`, `fullstack`) build cleanly with the full module set on the new pin.
