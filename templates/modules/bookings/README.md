# bookings — appointment / reservation scheduling

The **third** real feature module. It gives a project a genuinely working
**booking system**: a catalogue of bookable services, the available time slots
for each, and customer bookings that move through a `pending → confirmed →
cancelled` lifecycle — with **double-booking prevented server-side**, in the
database, not just in the UI. It is the feature the **clinic** and **real-estate**
presets need (appointments / viewing requests).

It needs **no external credentials** and **no extra container**. Unlike
[`content-admin`](../content-admin/README.md) (which ships its own Directus
service), bookings is an **in-app** module like
[`i18n-bilingual`](../i18n-bilingual/README.md): it layers a small API into the
base's **existing** .NET service and a booking UI into the base's **existing**
Next.js service, and it uses the **project's own** PostgreSQL database (reached by
service name — no secrets committed).

## What it declares

See [`module.manifest`](module.manifest):

- `status: implemented` — the generator composes it in.
- `base_compatible: all` — every base gets the right pieces via per-base
  `files/<base>/` subtrees (below); none falls back to the wrong half.
- `database: postgres` — it uses the **project's** relational DB via
  `ConnectionStrings__Default` (the generator builds this for `--db postgres` from
  the shared `.env` credentials). For `mysql` / `mongo` / `none` it degrades
  gracefully — see [Database & fallbacks](#database--fallbacks).
- `external_credentials: none` — fully self-contained.
- `files: files` — the per-base source it layers onto the project.
- `compose: none` — **no new service**; the API and UI run inside the base's
  existing containers.
- `caddy_routes: none` — the API lives under `/api/bookings/*` and the UI under
  `/booking` (and `/<locale>/booking`) on the project's existing subdomain, already
  fronted by the base `reverse_proxy`.
- `env: BOOKINGS_API_URL` — an **optional** override (empty template); see
  [nextjs-app integration](#nextjs-app-integration).

## Data model

Three tables, applied as **idempotent SQL** (PostgreSQL) by the backend on
startup. They are namespaced with a `bookings_` prefix so they never collide with
the project's other tables in the shared database. Full schema:
[`files/<base>/.../Bookings/migrations/001_init_bookings.sql`](files/dotnet-api/Bookings/migrations/001_init_bookings.sql).

| Table               | Purpose                            | Key columns                                                                 |
| ------------------- | ---------------------------------- | -------------------------------------------------------------------------- |
| `bookings_services` | bookable services / resources      | `slug` (unique), `name_en`/`name_ar`, `description_*`, `duration_minutes`, `active` |
| `bookings_slots`    | available time slots for a service | `service_id` → service, `starts_at`/`ends_at`, `capacity` (default 1), `active`, unique `(service_id, starts_at)` |
| `bookings_bookings` | bookings + their status            | `reference` (public token), `slot_id`, `service_id`, customer `name`/`email`/`phone`, `notes`, `status` (`pending`/`confirmed`/`cancelled`) |

Bilingual service names (`name_en` / `name_ar`) let the UI render Arabic or
English directly, cooperating with `i18n-bilingual`.

## How booking conflicts are prevented

Double-booking is blocked **server-side, at two layers** (never relying on the UI):

1. **Application — a row-locked capacity check.**
   [`BookingsRepository.CreateBookingAsync`](files/dotnet-api/Bookings/BookingsRepository.cs)
   runs in a transaction that first `SELECT … FOR UPDATE`s the slot row. Two
   concurrent requests for the **same slot** serialize on that lock, so the
   "count active (non-cancelled) bookings < capacity" check is **race-free** — the
   second request sees the first's booking and is rejected (`409 Conflict`,
   `SlotFull`). This honours **any** `capacity`.
2. **Database — a partial unique index (the hard backstop).** For the default
   single-capacity slot, `bookings_one_active_per_slot`
   (`UNIQUE (slot_id) WHERE status <> 'cancelled'`) makes a second active booking
   on a slot **impossible**, even if application code were bypassed. (If you
   deliberately set a slot's `capacity > 1`, drop this index and rely on layer 1 —
   see the comment in the migration.)

Cancelling a booking sets `status = 'cancelled'`, which the index and the count
both ignore — so the slot is freed and bookable again.

## The API

Minimal-API endpoints
([`BookingsEndpoints.cs`](files/dotnet-api/Bookings/BookingsEndpoints.cs)), wired
into `Program.cs`, on the base's existing service (no new routes/ports):

| Method & path                              | Does                                              | Notable responses                          |
| ------------------------------------------ | ------------------------------------------------- | ------------------------------------------ |
| `GET  /api/bookings/services`              | list active services                              | `200` (array)                              |
| `GET  /api/bookings/services/{id}/slots`   | available **future** slots with remaining > 0     | `200` (array)                              |
| `GET  /api/bookings/{id}`                  | fetch one booking                                 | `200` / `404`                              |
| `POST /api/bookings`                       | create a booking (`pending`)                      | `201` / `400` / `404` / **`409` (slot full/unavailable)** / `503` |
| `POST /api/bookings/{id}/confirm`          | `pending → confirmed`                             | `200` / `404` / `409`                      |
| `POST /api/bookings/{id}/cancel`           | `pending`/`confirmed → cancelled` (frees slot)    | `200` / `404` / `409`                      |

Validation is server-side (`slotId`, a non-empty `customerName`, a valid-looking
`customerEmail`). JSON is camelCase (ASP.NET web defaults), matching the frontend
client. The create response returns the booking with its public `reference`
(e.g. `BK-1A2B3C4D`).

## How the generator wires it

When a project requests `bookings`, the generator
([`scripts/new-project.sh`](../../../scripts/new-project.sh)) copies this module's
`files/<base>/` tree into the project (substituting `__PROJECT_NAME__`,
`__DEFAULT_LOCALE__`, …) and lists it under **Active modules** in `PROJECT.md`. No
compose fragment and no Caddy routes are added (`compose: none`,
`caddy_routes: none`). The per-base pieces:

- **`dotnet-api`** → the **API only** (it is an API base): `Program.cs` and
  `app.csproj` (which **replace** the base's — adding the `Bookings/` endpoints +
  migrator and the Npgsql dependency) and the `Bookings/` folder with the SQL
  migration.
- **`fullstack`** → the **API in `backend/`** *and* the **UI in `frontend/`** —
  the fully wired, end-to-end shape (the clinic / real-estate presets).
- **`nextjs-app`** → the **UI only** (`lib/`, `components/`, `app/booking`,
  `app/[locale]/booking`, `app/api/bookings`); it needs a separate API — see
  [nextjs-app integration](#nextjs-app-integration).

Because the only files that **replace** base files are the backend `Program.cs` /
`app.csproj` (everything else is additive new paths), bookings composes cleanly
**alongside** `i18n-bilingual` and `content-admin`: i18n only touches frontend
layout/routes, and content-admin only adds `DirectusClient.cs` / `lib/directus.js`
— no path collisions.

## How it connects to the database

The backend reads the **project's** connection string from the environment
variable `ConnectionStrings__Default`, which the base compose fragment sets and
the generator builds from the shared `.env` DB credentials — e.g. for
`--db postgres`:

```
Host=postgres;Port=5432;Database=${POSTGRES_DB};Username=${POSTGRES_USER};Password=${POSTGRES_PASSWORD}
```

So the app reaches the shared PostgreSQL **by service name** (`postgres:5432`) on
the `internal` network, with **no secret written into any committed file** (the
`${…}` are interpolated by Compose at runtime). On startup
[`BookingsMigrator`](files/dotnet-api/Bookings/BookingsMigrator.cs):

1. confirms the connection string is PostgreSQL (else logs and skips — see below);
2. waits (bounded retries) for the DB to accept connections — the shared DB is
   started separately, so it may lag the app's boot;
3. applies every `Bookings/migrations/*.sql` in order (idempotent);
4. **seeds** two sample services + upcoming slots **only when the services table
   is empty** (a brand-new install), so the flow is demonstrable immediately. Set
   `BOOKINGS_SEED=false` on the service to disable, or just delete/replace the
   samples. It never overwrites existing data.

The whole startup step is wrapped so a DB problem is **logged but never crashes
the app** — `/health` always comes up, and the booking endpoints return a clear
error until the DB is reachable.

## How it cooperates with i18n-bilingual

The booking UI is bilingual and RTL-aware on its own, and **slots into i18n's
locale routing when that module is also composed** — without depending on it:

- It ships its **own** tiny label set
  ([`lib/bookings-i18n.js`](files/nextjs-app/lib/bookings-i18n.js), ar/en) and
  reads the same `NEXT_PUBLIC_DEFAULT_LOCALE` and `pi_locale` cookie i18n uses, so
  the language stays in sync whether or not i18n is present. It never imports the
  i18n module's files.
- It ships the page at **both** locations so there is no broken reference in
  either mode:
  - **`app/booking/page.jsx`** — served at `/booking` when i18n is **not**
    composed (locale from the cookie / scaffold default).
  - **`app/[locale]/booking/page.jsx`** — when i18n **is** composed, its
    middleware redirects `/booking → /<locale>/booking`, and its
    `app/[locale]/layout.jsx` validates the locale and wraps this page. Both render
    the same `BookingWidget`.
- The browser-facing calls go to same-origin **Route Handlers** under
  `/api/bookings` (which the i18n middleware **skips**), and those run on the
  server and proxy to the internal backend — so the booking write is server-side
  and the internal API is never exposed to the browser.

Text direction is set on `<html dir>` by the base / i18n root layout; the widget
uses CSS **logical properties** so it mirrors automatically for Arabic.

## Database & fallbacks

Bookings is a relational feature, so it is **fully functional with
`--db postgres`** (the clinic / real-estate default). For other choices it stays
safe and self-documenting rather than broken:

| Project `--db`      | Behaviour                                                                                                  |
| ------------------- | --------------------------------------------------------------------------------------------------------- |
| `postgres`          | **Full functionality** — migrations applied, API live, double-booking enforced.                            |
| `mysql`             | Not supported as-is: the migrations and `BookingsRepository` use PostgreSQL (Npgsql). The migrator detects a non-PostgreSQL connection string, logs a warning and **skips** schema setup; the endpoints return `503`. To use bookings, generate with `--db postgres`. (Porting to MySQL means MySQL-flavoured SQL + a MySQL driver.) |
| `mongo` / `none`    | No relational DB to use → migrator logs and skips; endpoints return `503`. The app's `/health` and base endpoints keep working. Generate with `--db postgres` to enable bookings. |

In every case the **base scaffold stays healthy** — bookings simply reports
itself unavailable instead of crashing the service.

## nextjs-app integration

A `nextjs-app` base is **frontend-only** — it has no .NET backend, so the booking
UI it receives needs a **separate** bookings API to call. This is a documented
integration point, not a broken reference: with nothing wired, the UI renders and
shows an empty/"unavailable" state (it never errors). To wire it:

1. Deploy a bookings API — e.g. a separate `--base dotnet-api --modules bookings
   --db postgres` project, or any reachable .NET bookings service.
2. Set `BOOKINGS_API_URL` in `.env` to that API's internal address (e.g.
   `http://<api-name>:8080`).
3. Pass it into the web container by adding one line to the `environment:` of the
   web service in `services/<name>/<name>.compose.yml`:
   ```yaml
       environment:
         BOOKINGS_API_URL: ${BOOKINGS_API_URL:-}
   ```

> The simplest path to a working end-to-end booking flow is the **`fullstack`**
> base (used by the clinic / real-estate presets): there the frontend already
> reaches the backend via `BACKEND_URL`, so bookings works with **zero** extra
> configuration.

## Run it

```bash
# Composed automatically by the clinic and real-estate presets, or add it
# explicitly to a fullstack project (end-to-end out of the box):
./scripts/new-project.sh --name happy-teeth --preset clinic --subdomain teeth
#   or:
./scripts/new-project.sh --name acme --base fullstack --db postgres \
  --subdomain acme --modules bookings

# 1. Start the project's database (bookings needs postgres):
./scripts/db.sh postgres up
# 2. Ensure Caddy is up:
./scripts/start-proxy.sh
# 3. Build + start the project (the booking API + UI come up with it):
./scripts/project.sh up acme
```

Then open **`https://acme.<BASE_DOMAIN>/booking`** (with i18n it redirects to
`/ar/booking` or `/en/booking`): pick a service, choose an available time, submit
— you get a booking reference. On first boot the backend seeds a couple of sample
services + upcoming slots so this works immediately; replace them with your own
(or set `BOOKINGS_SEED=false`).

To manage bookings from the API directly (e.g. confirm/cancel):

```bash
# from the Pi (the API has no host port; use the internal network or a tunnel):
curl -X POST http://<name>-api:8080/api/bookings/1/confirm
curl -X POST http://<name>-api:8080/api/bookings/1/cancel
```

## Resource notes (Pi 5)

Bookings adds **no container** and **no new image** — it runs inside the base's
existing .NET and Next.js services and uses the project's existing PostgreSQL. The
only build-time addition is the pure-managed **Npgsql** NuGet package (pinned,
ARM64-safe). First boot does a little extra work (apply migrations + optional
seed), then it is negligible.

## Turning a planned module into an implemented one

`bookings` was promoted from the planned roadmap exactly as described in
[`../README.md`](../README.md#promoting-a-planned-module-to-implemented): build the
module folder, pick the contribution, set `database` / `external_credentials`
honestly, and drop it from the generator's planned list. The new lessons over the
first two modules:

- An in-app module can layer **both backend and frontend** code at once (a
  `files:` module that touches .NET *and* Next.js), and may **replace** a base
  file when it must (here `Program.cs` / `app.csproj`, to wire the API + add a
  dependency) while keeping everything else additive so it still composes with the
  other modules.
- A module can use the **project's own database** (via `ConnectionStrings__Default`,
  by service name) with `compose: none` — no dedicated container needed — and ship
  **idempotent SQL migrations** that the existing backend applies on startup.
- "Cooperates with i18n if present" is achieved by shipping a **self-contained**
  bilingual UI plus **both** the locale-agnostic and locale-prefixed routes, so
  there is no broken reference whether or not `i18n-bilingual` is composed.
