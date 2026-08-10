# whatsapp-integration — one-time WhatsApp Cloud API setup (operator-run, deferred)

Everything in this module is wired by the generator and the code **except** the
parts that require an **external Meta / WhatsApp Business account**. Those cannot be
done from code — they are **operator-run, once**, during the **final manual
session**. Until then a generated project **builds and runs** on the default **mock**
provider (messages are logged, the flow is fully testable); the steps below are what
flip it to **live** delivery.

> This is the **only** thing standing between mock and live: create the account,
> copy a few values into `.env`, set `WHATSAPP_PROVIDER=cloud_api`, restart. No code
> changes.

---

## What is automatic vs manual

| Automatic (already done by the generator / code) | Manual (you, at Meta, once) |
| ------------------------------------------------ | --------------------------- |
| Swappable provider (mock + Cloud API), send + webhook endpoints | **1.** Create a Meta app + WhatsApp Business account |
| `X-Hub-Signature-256` verification; mock default | **2.** Get a **phone number id** |
| Empty `.env` templates for every `WHATSAPP_*` value | **3.** Get a **permanent access token** |
| Compose env wiring; webhook URL is the app's own `/api/whatsapp/webhook` | **4.** Register the webhook (verify token + app secret); **5.** flip `.env` |

---

## 1. Create a Meta app + WhatsApp Business account

1. Go to <https://developers.facebook.com/> → **My Apps** → **Create App** →
   type **Business**.
2. In the app, add the **WhatsApp** product. This creates a **WhatsApp Business
   Account (WABA)** and a **test phone number** you can use immediately for
   development.
3. (For production) add and **verify your own business phone number** under
   **WhatsApp → API Setup**, and complete **Business Verification** in Meta Business
   Suite (required to message real users at scale and to send template messages).

---

## 2. Get the phone number id

In **WhatsApp → API Setup**, copy the **Phone number ID** (a long number — *not*
the phone number itself). This is **`WHATSAPP_PHONE_NUMBER_ID`**.

---

## 3. Get a permanent access token

The token shown on the API Setup page is **temporary (24h)** — fine for a first
test, useless for production. For a **permanent** token:

1. **Meta Business Suite → Business settings → Users → System users → Add** a
   system user (role: Admin or Employee).
2. **Assign assets** → add your **app** and your **WhatsApp account** with full
   control.
3. **Generate new token** → select the app → grant scopes **`whatsapp_business_messaging`**
   and **`whatsapp_business_management`** → **set expiry to *Never*** → generate.
4. Copy it — this is **`WHATSAPP_ACCESS_TOKEN`** (you cannot view it again).

---

## 4. (Optional) register the inbound webhook

Only needed if you want to **receive** messages / delivery-status events. The
endpoint is the project's own route — no extra hosting:

```
https://<subdomain>.<BASE_DOMAIN>/api/whatsapp/webhook
```

1. Pick a **verify token** — any string you choose. Put it in `.env` as
   **`WHATSAPP_VERIFY_TOKEN`**.
2. In the Meta app → **WhatsApp → Configuration → Webhook → Edit**:
   - **Callback URL**: the URL above.
   - **Verify token**: the same string.
   - Meta sends a `GET` handshake; the app echoes `hub.challenge` when the token
     matches → **Verify and save**.
3. **Subscribe** to the `messages` field (and any others you want).
4. Copy the app's **App secret** (App → **Settings → Basic → App secret → Show**)
   into `.env` as **`WHATSAPP_APP_SECRET`**. Inbound `POST`s are then verified
   against `X-Hub-Signature-256` (HMAC-SHA256 over the raw body).

> The public URL requires the project to be reachable over HTTPS — see
> `docs/cloudflare-tunnel.md`. For local `*.localhost` testing the GET verify works
> behind Caddy, but Meta cannot reach a non-public host to POST events.

---

## 5. Flip mock → live

In the **root `.env`** (never commit it):

```dotenv
WHATSAPP_PROVIDER=cloud_api
WHATSAPP_PHONE_NUMBER_ID=<from step 2>
WHATSAPP_ACCESS_TOKEN=<from step 3>
# only if you registered the inbound webhook (step 4):
WHATSAPP_VERIFY_TOKEN=<the token you chose>
WHATSAPP_APP_SECRET=<your Meta app secret>
# WHATSAPP_API_VERSION=v21.0   # optional; a sane version is pinned by default
```

Restart the project:

```bash
./scripts/project.sh up <name>
```

Send a real message (inside the 24h window, or use an approved template):

```bash
curl -k -X POST https://<subdomain>.<BASE_DOMAIN>/api/whatsapp/send \
  -H 'Content-Type: application/json' \
  -d '{"to":"9665XXXXXXXX","message":"Live from pi-system"}'
# -> {"success":true,"provider":"cloud_api","messageId":"wamid....","error":null}
```

To go back to mock at any time, set `WHATSAPP_PROVIDER=mock` (or blank) and restart.

---

## Notes

- **Templates vs free-form.** Outside the 24h customer-service window you may only
  send **pre-approved templates** (create + submit them under **WhatsApp → Message
  templates**). Send them via `{"template":"name","language":"ar","parameters":[...]}`.
- **Recipient format.** E.164 **without** a leading `+` (e.g. `9665XXXXXXXX`). The
  provider strips a `+` if present.
- **Rate / pricing.** WhatsApp charges per conversation and enforces messaging
  limits that grow with quality rating — review Meta's current pricing before bulk use.
