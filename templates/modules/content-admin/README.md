# content-admin — headless CMS (Directus)

The second **real** feature module. It gives any project a proper **content
management system** — a friendly admin UI for non-developers to edit pages,
posts, navigation and site settings — without committing a schema or writing a
custom back office. It integrates [Directus](https://directus.io), a mature,
open-source Node.js headless CMS, as a self-contained service on the platform's
internal network, and ships a clean, env-driven client for each base shape.

It needs **no external credentials**: the CMS admin user is created from
environment variables on first boot. It runs entirely **internal-only** (no host
ports, not on the public `proxy` network); your app calls its API server-side
over the Docker `internal` network, and you reach the `/admin` UI over an SSH
tunnel (below).

## What it declares

See [`module.manifest`](module.manifest):

- `status: implemented` — the generator composes it in.
- `base_compatible: all` — the CMS container runs for **every** base; each base
  also gets the right client (Next.js wrapper for `nextjs-app` / `fullstack`
  frontend, a .NET helper for `dotnet-api` / `fullstack` backend).
- `database: postgres` — Directus supports any SQL DB, but this module **ships
  its own dedicated, isolated PostgreSQL** in the compose fragment, so it works
  regardless of the project's own `--db` choice (postgres / mysql / mongo / none).
- `external_credentials: none` — the admin user comes from env vars.
- `compose: service.compose.yml` — stands up Directus + its private DB.
- `files: files` — the per-base client wrappers it layers onto the project.
- `caddy_routes: none` — internal-only, so no public route is added.
- `env:` — the empty templates `CMS_KEY`, `CMS_SECRET`, `CMS_ADMIN_EMAIL`,
  `CMS_ADMIN_PASSWORD`, `CMS_DB_PASSWORD`, `CMS_PUBLIC_URL` (filled in `.env`).

## How the generator wires it

When a project requests `content-admin`, the generator (`scripts/new-project.sh`):

1. **Compose.** Copies [`service.compose.yml`](service.compose.yml) to
   `services/<name>/<name>.content-admin.compose.yml`, substituting the project
   name. `scripts/project.sh` loads it alongside the main fragment, so
   `./scripts/project.sh up <name>` brings the CMS up with the project. It adds
   two services — `<name>-cms` (Directus) and `<name>-cms-db` (its private
   PostgreSQL) — both `internal`-only, no host ports.
2. **Files.** Copies this module's `files/<base>/` tree into the project:
   - `nextjs-app` → `lib/directus.js` at the app root.
   - `fullstack` → `frontend/lib/directus.js` **and** `backend/DirectusClient.cs`.
   - `dotnet-api` → `DirectusClient.cs` next to `Program.cs`.

   All are **additive** (new paths) — they never overwrite the base or the
   `i18n-bilingual` files, so the two modules compose together cleanly.
3. **Env.** Appends the `CMS_*` empty templates to the project's `.env.example`
   section, labelled `(module: content-admin)`.
4. **Record.** Lists `content-admin` under **Active modules** in `PROJECT.md`.

## Run it

```bash
# Composed automatically by any preset that lists it (clinic, ecommerce,
# company-site, real-estate), or add it explicitly:
./scripts/new-project.sh --name acme-site --base fullstack --db postgres \
  --subdomain acme --modules content-admin

# 1. Fill the CMS secrets in .env (copy the new PROJECT section from .env.example):
#      CMS_KEY=...            # e.g. openssl rand -hex 32
#      CMS_SECRET=...         # e.g. openssl rand -hex 32   (distinct from KEY)
#      CMS_ADMIN_EMAIL=you@example.com
#      CMS_ADMIN_PASSWORD=...
#      CMS_DB_PASSWORD=...
# 2. Bring it up (the CMS comes up with the project):
./scripts/project.sh up acme-site
```

On first boot Directus runs its migrations and creates the admin user from
`CMS_ADMIN_EMAIL` / `CMS_ADMIN_PASSWORD` (~15–30s, longer on a cold Pi).

## Accessing the admin UI (`/admin`)

By design the CMS is **internal-only** — it publishes no host ports and is not on
the public `proxy` network, so it is never exposed to the internet (the same
posture as the platform's other admin tools). Directus serves its admin app at
the **`/admin`** path and its API at the root (`/items/...`, `/server/health`).

To open `/admin` in your browser, use the **commented bootstrap port** in
`services/<name>/<name>.content-admin.compose.yml` plus an SSH tunnel:

```bash
# 1. In <name>.content-admin.compose.yml, uncomment under the `__PROJECT_NAME__-cms`
#    service:
#        ports:
#          - "127.0.0.1:${CMS_BOOTSTRAP_PORT:-8055}:8055"
#    (binds to 127.0.0.1 on the Pi ONLY — never the LAN), then:
./scripts/project.sh up <name>

# 2. From your machine, tunnel to the Pi and browse the admin UI:
ssh -L 8055:127.0.0.1:8055 <user>@<pi-host>
#    → open http://localhost:8055/admin   (log in with CMS_ADMIN_EMAIL/PASSWORD)

# 3. Re-comment the port and re-run `up` when you are done.
```

This keeps the CMS off the public edge while still giving you full admin access.
(If you later decide to expose it deliberately, you would put the service on the
`proxy` network and add a Caddy block — out of scope for this internal-only
module.)

## Suggested data model (frontend-agnostic)

No schema is committed — you build collections in `/admin` to fit the project.
A clean, frontend-agnostic starting point that the shipped client helpers expect:

| Collection   | Type      | Suggested fields                                                        |
| ------------ | --------- | ---------------------------------------------------------------------- |
| `pages`      | normal    | `status` (draft/published), `slug`, `title`, `body` (rich text), `sort`|
| `posts`      | normal    | `status`, `slug`, `title`, `excerpt`, `body`, `date_published`, `image`|
| `navigation` | normal    | `sort`, `label`, `url`, `parent` (self-relation for nesting)           |
| `settings`   | singleton | `site_title`, `logo`, `primary_color`, `contact_email`, `social`       |

Tips:
- Give text fields a translations interface if you pair this with
  `i18n-bilingual` (Directus has first-class field translations for ar/en).
- For **public** read access (the simplest setup), in *Settings → Access Policies
  → Public* grant **read** on the collections above. Then the app needs no token.
- PostgreSQL `json`/`jsonb` fields are great for flexible, repeatable content
  (e.g. a page's section blocks).

## Writing frontend queries (Next.js)

The module ships `lib/directus.js` (server-side only). The CMS base URL is baked
in to the internal service address; override with `DIRECTUS_URL` if needed.

```jsx
// app/page.jsx (a Server Component)
import { getPage, getNavigation, getSettings } from '../lib/directus';

export const dynamic = 'force-dynamic'; // or set DIRECTUS_REVALIDATE for ISR

export default async function Home() {
  const [home, nav, settings] = await Promise.all([
    getPage('home'),       // one published page by slug
    getNavigation(),       // ordered nav items
    getSettings(),         // the settings singleton
  ]);

  return (
    <main>
      <h1>{settings?.site_title ?? '__PROJECT_NAME__'}</h1>
      <nav>{(nav ?? []).map((n) => <a key={n.id} href={n.url}>{n.label}</a>)}</nav>
      <article dangerouslySetInnerHTML={{ __html: home?.body ?? '' }} />
    </main>
  );
}
```

- Generic escape hatches: `getItems(collection, params)`,
  `getItemByField(collection, field, value)`, `getSingleton(collection)`,
  `directusFetch(path, { params })`. `params` maps to Directus query syntax
  (`{ filter: { status: { _eq: 'published' } }, fields: '*', sort: '-date' }`).
- Every helper **degrades gracefully** (returns `[]` / `null`) if the CMS is
  still booting or a collection does not exist yet — pages never crash.
- Build asset URLs server-side with the exported `directusUrl`:
  `` `${directusUrl}/assets/${fileId}` ``.

### Authenticated reads (optional)

If you keep collections private, create a **static access token** in Directus
(*User → Token*) and pass it to the app as `DIRECTUS_TOKEN`. Add it to the app
service's environment in `services/<name>/<name>.compose.yml`:

```yaml
    environment:
      DIRECTUS_TOKEN: ${CMS_READ_TOKEN:-}   # then add CMS_READ_TOKEN= to .env
```

The wrapper sends it as a `Bearer` header automatically when present.

## Backend (.NET) guidance

For a `dotnet-api` base or the `fullstack` backend, the module ships
`DirectusClient.cs` — a small, **optional** client that calls the CMS over the
internal network. It uses the built-in `HttpClient` + `System.Text.Json`, so it
**compiles with zero extra packages** and won't break the build; delete it if you
don't call the CMS from .NET.

```csharp
// Program.cs — register it (recommended: via IHttpClientFactory)
builder.Services.AddHttpClient<ContentAdmin.DirectusClient>();

app.MapGet("/api/pages", async (ContentAdmin.DirectusClient cms) =>
{
    var pages = await cms.GetPublishedAsync<Dictionary<string, object>>("pages");
    return Results.Ok(pages);
});
```

**Suggested upgrade — RestSharp.** For a richer, fluent client (typed requests,
query builders, auth handlers), install RestSharp and swap the calls:

```bash
dotnet add package RestSharp
```

```csharp
var client = new RestSharp.RestClient("http://__PROJECT_NAME__-cms:8055");
var req = new RestSharp.RestRequest("/items/pages")
    .AddQueryParameter("filter[status][_eq]", "published")
    .AddQueryParameter("fields", "*");
var pages = await client.GetAsync(req);   // deserialize the { "data": [...] } envelope
```

Both approaches reach the CMS at the internal address
`http://__PROJECT_NAME__-cms:8055`; like the frontend, prefer **public read
access** on your collections, or send a static token via an `Authorization:
Bearer` header.

## Resource notes (Pi 5)

The CMS adds two containers: Directus (Node, 512M limit) and its PostgreSQL
(256M). They are on-demand like everything else — bring the project down when
idle. First boot is the heaviest moment (schema install + migrations).

## Turning a planned module into an implemented one

`content-admin` was promoted from the planned roadmap exactly as described in
[`../README.md`](../README.md#promoting-a-planned-module-to-implemented): build
the module folder, pick the contribution (here a **`compose:` service** *and* a
per-base **`files:`** client), set `database` / `external_credentials` honestly,
and drop it from the generator's planned list. Because every preset that lists it
already did so, those presets now compose it automatically instead of recording a
TODO. The new lesson over `i18n-bilingual`: a module can ship **both** a service
and per-base in-app code, and it can be `base_compatible: all` by providing a
distinct `files/<base>/` subtree for each base (so no base falls back to the
wrong client).
