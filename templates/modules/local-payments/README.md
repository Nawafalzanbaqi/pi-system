# local-payments — local payment checkout (swappable provider)

Take payments — **mada**, Apple Pay and cards — from a generated project, behind
**one clean internal interface** with **two interchangeable providers**:

- a **mock** provider (the **default**) that simulates the **entire lifecycle**
  locally — create an intent → "pay" → an **HMAC-signed webhook** → mark paid →
  expose status — so the whole flow runs and is testable **right now with no
  merchant account**; and
- a **real** provider, **Moyasar** (a Saudi gateway), fully coded, that becomes
  active the moment you set `PAYMENTS_PROVIDER=moyasar` and supply your API key —
  **nothing else in the app changes**.

This is the **swappable-provider** design: the live provider is chosen **once at
start-up** from `PAYMENTS_PROVIDER`; the endpoints + repository depend only on
`IPaymentProvider`, so flipping **mock → live** is a pure environment change. The
real provider is **inert until its credentials are present** — see
[SETUP.md](SETUP.md) for the deferred, one-time Moyasar steps.

| Manifest | Value |
| -------- | ----- |
| `status` | `implemented` |
| `base_compatible` | `all` (per-base pieces — see below) |
| `database` | `postgres` (records intents/status; idempotent — no double-credit) |
| `external_credentials` | **required to go live** (Moyasar merchant) — **not** to build/run (mock default) |
| `compose` | `compose` (per-base fragments; merge env, no new container) |
| `caddy_routes` | `none` (routes live under the app's `/api/payments/*`) |

## Why Moyasar?

[Moyasar](https://moyasar.com) is a well-documented Saudi payment gateway with a
simple public REST API that supports the methods the **local market** needs —
**mada**, Apple Pay and credit/debit cards — through a single **hosted-invoice**
flow, so no card data ever touches this server. (HyperPay is the other common Saudi
choice; its COPYandPAY integration is heavier. Moyasar keeps the module
self-contained while remaining a genuine, production-grade integration.) Adding a
second real provider is just another `IPaymentProvider` implementation + a branch in
`PaymentsHostingStartup`.

---

## What each base gets

| Base | What it ships |
| ---- | ------------- |
| `dotnet-api` | The .NET payment service: `POST /api/payments` (create), `GET /api/payments/{ref}` (status), `POST /api/payments/webhook` (verified), `POST /api/payments/mock/pay/{ref}` (mock only). |
| `fullstack` | The .NET service in the **backend** (source of truth) **plus** the Next.js **checkout** + **return** pages and the server-side proxy Route Handlers in the frontend. The end-to-end shape used by the `ecommerce` preset. |
| `nextjs-app` | The checkout + return UI and proxy routes calling a payments backend over `PAYMENTS_API_URL` — a documented integration point (see below). |

All HTTP lives under the app's own routes (no new host ports, no Caddy changes).

---

## The payment lifecycle

```
POST /api/payments              -> persist a PENDING intent, ask the provider to
   { amount, currency?, ... }      create the payment, return { reference,
                                    redirectUrl | mockPayUrl }
   (real)  browser -> redirectUrl (Moyasar hosted page: mada / Apple Pay / card)
   (mock)  POST mockPayUrl  -> emits an HMAC-signed webhook to the app
provider/webhook -> POST /api/payments/webhook  -> VERIFY signature/secret, then
                                    record the status IDEMPOTENTLY (pending -> paid
                                    once; replays are no-ops; no double-credit)
GET  /api/payments/{reference}  -> the current status (the return page polls this)
```

**Idempotency / no double-credit** is enforced server-side in `PaymentsRepository`:
the webhook locks the payment row (`SELECT … FOR UPDATE`) and moves `pending → paid`
**at most once** (stamping `paid_at` a single time); a replayed or duplicate webhook
finds the row already paid and is a no-op. A partial unique index on
`(provider, provider_payment_id)` is the database-level backstop.

**Webhook verification is mandatory.** Each provider verifies in its own documented
way before any status is trusted: the **mock** checks an `HMAC-SHA256` signature
(`X-Mock-Signature`) over the raw body using `PAYMENTS_WEBHOOK_SECRET`; **Moyasar**
compares the `secret_token` carried in the payload (its documented mechanism). Both
use a constant-time compare.

---

## Try it now (mock — no account needed)

```bash
./scripts/new-project.sh --name shop --base fullstack --db postgres \
  --subdomain shop --modules local-payments
./scripts/db.sh postgres up
./scripts/project.sh up shop

# 1) create a payment (amount in halalas: 1000 = 10.00 SAR)
curl -k -X POST https://shop.localhost/api/payments \
  -H 'Content-Type: application/json' -d '{"amount":1000,"description":"Test order"}'
# -> {"reference":"PAY-...","provider":"mock","status":"pending","mockPayUrl":"/api/payments/mock/pay/PAY-..."}

# 2) simulate paying (emits the signed webhook -> verified -> marked paid)
curl -k -X POST https://shop.localhost/api/payments/mock/pay/PAY-...

# 3) status is now paid
curl -k https://shop.localhost/api/payments/PAY-...
# -> {"reference":"PAY-...","status":"paid","amountMinor":1000,"currency":"SAR", ...}
```

Or open `https://shop.localhost/checkout` (or `/<locale>/checkout` with i18n) and use
the **Pay → Simulate** buttons; the return page shows the paid status. This proves
the full path — create → pay → **signature-verified** webhook → **idempotent** record
→ status — works with zero credentials.

---

## Going live (Moyasar)

1. Do the one-time Moyasar steps in [SETUP.md](SETUP.md) (open a merchant account,
   get your **secret API key**, set the **webhook** + its **secret token**).
2. In the **root `.env`**, set:
   ```dotenv
   PAYMENTS_PROVIDER=moyasar
   PAYMENTS_API_KEY=sk_live_xxx            # Moyasar secret key
   PAYMENTS_WEBHOOK_SECRET=<webhook secret token you set in Moyasar>
   PAYMENTS_CURRENCY=SAR
   ```
3. Restart: `./scripts/project.sh up <name>`. That single env flip is the **only**
   thing standing between mock and live — the code is identical. `mada` is offered
   automatically on Moyasar's hosted page for SAR payments.

---

## Database & fallbacks

`database: postgres` — the module records intents/status in the **project's own**
PostgreSQL via `ConnectionStrings__Default` (by service name, shared `.env`
credentials, no dedicated container), so it is fully functional with `--db postgres`
(the `ecommerce` preset default). For `--db mysql`, `mongo` or `none` it **degrades
gracefully**: the `.NET` service stays healthy and the payment endpoints return a
clear `503` (the repository reports unavailable) instead of crashing. To use it,
generate with `--db postgres`.

## nextjs-app integration

A plain `nextjs-app` has no .NET backend, so the lifecycle (DB, webhook
verification, idempotency) lives in a **separate .NET payments service** — generate
one with the `dotnet-api` base + `local-payments`, then set `PAYMENTS_API_URL` on the
nextjs-app project to point at it. The shipped checkout/return UI and proxy routes
then work unchanged. Until `PAYMENTS_API_URL` is set the checkout degrades gracefully
(a clear 503) — never a broken reference. (On `fullstack` this is automatic via
`BACKEND_URL`; on `dotnet-api` the service *is* the backend.)

---

## How it composes with other modules

The .NET half is **additive**, like `auth-sso` / `whatsapp-integration`:

- It ships `Payments/PaymentsHostingStartup.cs` — an `[assembly: HostingStartup]`
  activated by `ASPNETCORE_HOSTINGSTARTUPASSEMBLIES=app` (set by the compose
  fragment). It does **not** replace `Program.cs` / `app.csproj`, so it composes
  cleanly with **bookings** (which owns those) and **auth-sso**/**whatsapp** (other
  HostingStartups in the same `app` assembly — the host runs all of them).
- It needs the **Npgsql** driver, added by a `Directory.Build.targets` that is
  **conditional**: if `bookings` is also composed (its `app.csproj` already
  references Npgsql) the targets **skips** it, so the package is never added twice;
  otherwise it adds it. Using `.targets` (not `.props`) also avoids a filename clash
  with auth-sso's `Directory.Build.props`.
- All files live under `Payments/` (backend) or `app/checkout`, `app/payment`,
  `app/api/payments`, `components/*`, `lib/payments*` (frontend) — **no path
  collisions** with any other module. It also cooperates with `i18n-bilingual` by
  shipping each page at both `/checkout` and `/<locale>/checkout` (and likewise the
  return page), without depending on it.

See [SETUP.md](SETUP.md) for the deferred, one-time Moyasar onboarding.
