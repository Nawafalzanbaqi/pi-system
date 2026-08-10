# local-payments — one-time Moyasar setup (operator-run, deferred)

Everything in this module is wired by the generator and the code **except** the
parts that require an **external merchant account** with the payment provider. Those
cannot be done from code — they are **operator-run, once**, during the **final
manual session**. Until then a generated project **builds and runs** on the default
**mock** provider, which simulates the entire lifecycle (so the flow is fully
testable); the steps below flip it to **live** payments.

> This is the **only** thing standing between mock and live: open the merchant
> account, copy a couple of values into `.env`, set `PAYMENTS_PROVIDER=moyasar`,
> restart. No code changes.

We use **Moyasar** (Saudi market: mada / Apple Pay / cards). HyperPay or another
gateway would be a second `IPaymentProvider` implementation — same shape.

---

## What is automatic vs manual

| Automatic (already done by the generator / code) | Manual (you, at Moyasar, once) |
| ------------------------------------------------ | ------------------------------ |
| Swappable provider (mock + Moyasar), create / status / webhook endpoints | **1.** Open a Moyasar **merchant account** |
| Idempotent recording; `secret_token` verification | **2.** Get your **secret API key** |
| Empty `.env` templates for every `PAYMENTS_*` value | **3.** Add a **webhook** + set its **secret token** |
| Callback + webhook URLs derived from the subdomain | **4.** Flip `.env` to go live |

---

## 1. Open a Moyasar merchant account

1. Sign up at <https://moyasar.com> and complete merchant onboarding / KYC (business
   details, IBAN for settlement). mada + Apple Pay + cards are enabled per your
   account configuration.
2. In the **Dashboard**, you operate in **test** mode first (keys prefixed
   `sk_test_` / `pk_test_`), then switch to **live** (`sk_live_` / `pk_live_`).

---

## 2. Get your secret API key

**Dashboard → Settings → API keys**. Copy the **Secret key** (`sk_test_…` to start,
`sk_live_…` for production). This is **`PAYMENTS_API_KEY`** — it is used as the HTTP
Basic-auth username for server-side calls. (The **publishable** key `pk_…` is only
needed for a client-side Moyasar.js form, which this module does not require — the
server-side hosted-invoice flow is used instead. You may still set
`PAYMENTS_PUBLISHABLE_KEY` if you later add a client form.)

> Keep the secret key server-side only. It is read from `.env` and injected into the
> backend container — it never reaches the browser.

---

## 3. Add the webhook + secret token

The webhook is the **source of truth** for settlement (the browser redirect is not
trusted). The endpoint is the project's own route — no extra hosting:

```
https://<subdomain>.<BASE_DOMAIN>/api/payments/webhook
```

1. **Dashboard → Settings → Webhooks → Add webhook**:
   - **URL**: the URL above.
   - **Events**: at least `payment_paid` (add `payment_failed`, `payment_refunded`
     as you wish).
   - **Secret token**: choose a strong random string. Moyasar includes it as
     `secret_token` in every webhook payload; the backend compares it (constant-time)
     and rejects mismatches.
2. Put that same string in `.env` as **`PAYMENTS_WEBHOOK_SECRET`**.

> The public URL requires the project to be reachable over HTTPS — see
> `docs/cloudflare-tunnel.md`. On `fullstack` / `nextjs-app` the web service is what
> Caddy fronts, so the webhook lands on the frontend and is proxied (raw body intact)
> to the internal .NET backend; on `dotnet-api` it hits the service directly.

---

## 4. Flip mock → live

In the **root `.env`** (never commit it):

```dotenv
PAYMENTS_PROVIDER=moyasar
PAYMENTS_API_KEY=sk_live_xxxxxxxxxxxxxxxx
PAYMENTS_WEBHOOK_SECRET=<the webhook secret token from step 3>
PAYMENTS_CURRENCY=SAR
# PAYMENTS_PUBLISHABLE_KEY=pk_live_...   # optional; only for a client-side form
```

Restart the project:

```bash
./scripts/db.sh postgres up        # the project's own DB must be running
./scripts/project.sh up <name>
```

Create a payment and pay it on Moyasar's hosted page (mada / Apple Pay / card):

```bash
curl -k -X POST https://<subdomain>.<BASE_DOMAIN>/api/payments \
  -H 'Content-Type: application/json' -d '{"amount":1000,"description":"Order"}'
# -> { "reference":"PAY-...", "provider":"moyasar", "redirectUrl":"https://.../invoice/...", ... }
# open redirectUrl, pay, you return to /payment/return?ref=PAY-...
# the webhook then marks it paid; GET /api/payments/PAY-... shows status: paid
```

To go back to mock at any time, set `PAYMENTS_PROVIDER=mock` (or blank) and restart.

---

## Notes

- **Amounts are in the minor unit** — halalas for SAR (1000 = 10.00 SAR). The API,
  DB and UI all use minor units to avoid floating-point money bugs.
- **Test vs live keys.** Validate end-to-end with `sk_test_` keys + Moyasar's test
  cards first; only then switch to `sk_live_` and re-register the webhook for the
  live environment.
- **mada.** mada is offered automatically on the hosted page for SAR payments once
  your account is approved for it — no extra code.
- **Reconciliation.** The webhook is authoritative. If you ever miss a webhook, you
  can re-query a payment via Moyasar's API and replay it through
  `/api/payments/webhook`; recording is idempotent, so it will not double-credit.
