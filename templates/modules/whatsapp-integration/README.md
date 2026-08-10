# whatsapp-integration — WhatsApp messaging (swappable provider)

Send WhatsApp messages — notifications and pre-approved templates — from a
generated project, behind **one clean internal interface** with **two
interchangeable providers**:

- a **mock** provider (the **default**) that logs the message and returns success,
  so the whole flow runs and is testable **right now with no external account**; and
- a **real** WhatsApp **Cloud API (Meta)** provider, fully coded, that becomes
  active the moment you set `WHATSAPP_PROVIDER=cloud_api` and supply Meta
  credentials — **nothing else in the app changes**.

This is the **swappable-provider** design: the live provider is chosen **once at
start-up** from `WHATSAPP_PROVIDER`; callers depend only on the interface
(`IWhatsappSender` in .NET, `getSender()` in JS), so flipping **mock → live** is a
pure environment change. The real provider is **inert until its credentials are
present** — see [SETUP.md](SETUP.md) for the deferred, one-time Meta steps.

| Manifest | Value |
| -------- | ----- |
| `status` | `implemented` |
| `base_compatible` | `all` (per-base pieces — see below) |
| `database` | `none` (sending is stateless) |
| `external_credentials` | **required to go live** (Meta / WhatsApp Business) — **not** to build/run (mock default) |
| `compose` | `compose` (per-base fragments; merge env, no new container) |
| `caddy_routes` | `none` (routes live under the app's `/api/whatsapp/*`) |

---

## What each base gets

The generator copies the right subtree for the project's base shape:

| Base | What it ships |
| ---- | ------------- |
| `dotnet-api` | The .NET sender service + example endpoints (`Whatsapp/`). A separate client/flow calls it to send. |
| `fullstack` | The .NET sender in the **backend** (the source of truth — it holds the token) **plus** a Next.js **server-side** helper (`lib/whatsapp.js`) that proxies to it. The end-to-end shape used by the `clinic` / `real-estate` presets. |
| `nextjs-app` | A **self-contained** Next.js (server-side) sender — the same swappable provider implemented in JS (`lib/whatsapp/`) + Route Handlers — so the flow runs with **no backend**. |

All HTTP lives under the app's own routes (no new host ports, no Caddy changes):

```
GET  /api/whatsapp/status     active provider + whether it can really send
POST /api/whatsapp/send       send a text or a template
GET  /api/whatsapp/webhook    Meta webhook verify handshake (echoes hub.challenge)
POST /api/whatsapp/webhook    inbound messages / status — X-Hub-Signature-256 verified
```

---

## Try it now (mock — no account needed)

Generate any base with this module (here a fullstack project), bring it up, and
send a message — the mock logs it and returns success:

```bash
./scripts/new-project.sh --name demo --base fullstack --db postgres \
  --subdomain demo --modules whatsapp-integration
./scripts/project.sh up demo

# send a text via the app (Caddy fronts it). The mock "delivers" by logging:
curl -k -X POST https://demo.localhost/api/whatsapp/send \
  -H 'Content-Type: application/json' \
  -d '{"to":"9665XXXXXXXX","message":"Hello from pi-system (mock)"}'
# -> {"success":true,"provider":"mock","messageId":"wamid.MOCK-...","error":null}

curl -k https://demo.localhost/api/whatsapp/status
# -> {"provider":"mock","configured":true, ...}
```

`./scripts/project.sh logs demo` shows the `whatsapp(mock): TEXT -> ...` line —
proof the full path (HTTP → provider → result) works with zero credentials.

---

## Going live (Cloud API)

1. Do the one-time Meta steps in [SETUP.md](SETUP.md) (create a WhatsApp Business
   account, get a **phone number id** + a **permanent access token**, choose a
   **verify token**, note your **app secret**).
2. In the **root `.env`**, set:
   ```dotenv
   WHATSAPP_PROVIDER=cloud_api
   WHATSAPP_PHONE_NUMBER_ID=<from Meta>
   WHATSAPP_ACCESS_TOKEN=<permanent token from Meta>
   # only if you receive inbound webhooks:
   WHATSAPP_VERIFY_TOKEN=<a token you choose>
   WHATSAPP_APP_SECRET=<your Meta app secret>
   ```
3. Restart: `./scripts/project.sh up <name>`. That single env flip is the **only**
   thing standing between mock and live — the code is identical.

> Templates: outside the 24-hour customer-service window WhatsApp only allows
> **pre-approved message templates**. Use `POST /api/whatsapp/send` with
> `{"template":"...","language":"ar","parameters":[...]}`. Free-form `message`
> text is for replies inside the 24h window.

---

## Cooperating with bookings

This module ships `WhatsappNotifications.SendBookingConfirmationAsync(...)` (a
`IWhatsappSender` extension) that takes **plain arguments** — it does **not**
reference any bookings type, so it compiles whether or not `bookings` is composed.
When both modules are present, send a confirmation from the bookings confirm flow:

```csharp
// inside the booking-confirm handler (you own the DI scope via ctx.RequestServices)
var sender = ctx.RequestServices.GetRequiredService<PiSystem.Whatsapp.IWhatsappSender>();
await sender.SendBookingConfirmationAsync(
    booking.CustomerPhone, booking.Reference, serviceName, booking.StartsAt, locale);
```

If `bookings` is **not** composed, the helper is still a ready-to-use building
block and nothing references it — **no broken reference** either way. (The `bookings`
module's files are not modified by this module; wiring the call is a one-line,
opt-in edit you make when you want booking-confirmation messages.)

---

## How it composes with other modules

The .NET half is **additive**, exactly like `auth-sso`:

- It ships `Whatsapp/WhatsappHostingStartup.cs` — an `[assembly: HostingStartup]`
  activated by `ASPNETCORE_HOSTINGSTARTUPASSEMBLIES=app` (set by the compose
  fragment). It does **not** replace `Program.cs` / `app.csproj`, so it composes
  cleanly with **bookings** (which owns those) and **auth-sso** (another
  HostingStartup in the same `app` assembly — the host runs all of them).
- It needs **no NuGet package** (built-in `HttpClient` + `System.Text.Json`), so it
  adds **no** `Directory.Build.props` / `.targets` — no chance of clashing with
  auth-sso's props or local-payments' targets.
- All files are under `Whatsapp/` (backend) or `lib/whatsapp` + `app/api/whatsapp`
  (frontend), so there are **no path collisions** with any other module.

Fail-soft: a send never throws — providers return a `WhatsappSendResult`
(`success`, `provider`, `messageId`, `error`). An inert Cloud API (selected without
credentials) returns a clear error and `status` reports `configured: false`.

---

## Security notes

- The **access token is server-side only** — on `fullstack` the browser talks to the
  Next.js server, which proxies to the .NET backend; the token never leaves the
  internal network.
- The inbound webhook verifies Meta's **`X-Hub-Signature-256`** (HMAC-SHA256 over
  the raw body using `WHATSAPP_APP_SECRET`) with a constant-time compare. With no
  app secret set (dev), it accepts but logs a warning — **set it before going live**.
- Phone numbers are redacted in logs (last 4 digits only).

See [SETUP.md](SETUP.md) for the deferred, one-time Meta onboarding.
