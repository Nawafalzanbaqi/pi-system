# auth-sso — one-time Keycloak setup (operator-run, deferred)

Everything in `auth-sso` is wired by the generator and the code **except** the
parts that must be done in the **Keycloak admin console** — creating a realm and a
**client per project**. Those cannot be done safely from code (they configure the
running identity provider), so they are **operator-run, once**, during the **final
manual session**. Until then a generated project **builds and runs**; its auth
endpoints just report `503` (auth OFF) — the rest of the app is unaffected.

> This configures the **existing** Keycloak (service `keycloak`, reached at
> `https://auth.${BASE_DOMAIN}`). It does **not** change Keycloak's deployment.

---

## What is automatic vs manual

| Automatic (already done by the generator / code) | Manual (you, in the Keycloak console, once) |
| ------------------------------------------------ | ------------------------------------------- |
| Frontend OIDC client (Auth Code + PKCE), backend JWT validation | **1.** Create / choose a **realm** |
| Compose env wiring; redirect & post-logout URIs **derived from the subdomain** | **2.** Create a **confidential client** for each project |
| Empty `.env` templates for the OIDC values | **3.** Copy the client **id + secret** into `.env` |
| JWKS-based signature/issuer validation | **4.** (Optional) add an **audience mapper**; set **5.** `OIDC_ISSUER_URL` |

---

## Before you start

Pick the values for the project you generated:

- `BASE_DOMAIN` — your platform domain, e.g. `example.com` (from `.env`).
- `SUBDOMAIN` — the project's subdomain, e.g. `teeth` (what you passed to
  `--subdomain`; the project is served at `https://<subdomain>.<BASE_DOMAIN>`).
- `REALM` — the realm name you'll use, e.g. `pi`. **One realm can serve many
  projects** (a client each), so you typically create it once and reuse it.
- `PREFIX` — the project's env prefix = the project name upper-cased with
  non-alphanumerics as `_` (e.g. project `happy-teeth` → `HAPPY_TEETH`).

Worked example used below: `BASE_DOMAIN=example.com`, `SUBDOMAIN=teeth`,
`REALM=pi`, project `happy-teeth` → `PREFIX=HAPPY_TEETH`.

---

## 1. Create (or choose) a realm

1. Sign in to `https://auth.${BASE_DOMAIN}/admin/` with the Keycloak bootstrap
   admin (`KC_BOOTSTRAP_ADMIN_*` from `.env`).
2. Top-left realm selector → **Create realm** → **Realm name**: `pi` → **Create**.
   (Skip if you already have a realm to reuse.)

The realm's OIDC issuer URL is then:

```
https://auth.example.com/realms/pi
```

This is the value for **`OIDC_ISSUER_URL`** (step 5).

---

## 2. Create a confidential client for the project

In the `pi` realm → **Clients** → **Create client**:

1. **General settings**
   - **Client type**: `OpenID Connect`
   - **Client ID**: a stable id for this project, e.g. `happy-teeth`
   - **Next**
2. **Capability config**
   - **Client authentication**: **On** → this makes it a **confidential** client
     (it gets a secret). Good for a server-side web app.
   - **Authorization**: Off
   - **Authentication flow**: keep **Standard flow** (Authorization Code) checked;
     uncheck the rest. **Next** → **Save**.
3. **Settings → Access settings** — enter the project's URLs (derived from the
   subdomain). For `teeth.example.com`:

   | Field | Value |
   | ----- | ----- |
   | **Root URL** | `https://teeth.example.com` |
   | **Home URL** | `https://teeth.example.com/` |
   | **Valid redirect URIs** | `https://teeth.example.com/api/auth/callback` |
   | **Valid post logout redirect URIs** | `https://teeth.example.com/` |
   | **Web origins** | `https://teeth.example.com` |

   > These must match what the app sends. The compose fragment derives exactly
   > `https://<subdomain>.${BASE_DOMAIN}/api/auth/callback` (redirect) and
   > `https://<subdomain>.${BASE_DOMAIN}/` (post-logout) — so use those. Avoid
   > wildcards. If you overrode `OIDC_REDIRECT_URI` in `.env`, register that value
   > instead.

4. **Advanced → Proof Key for Code Exchange (PKCE)**: set **PKCE Code Challenge
   Method** to `S256`. (The app always sends PKCE; this enforces it.)
5. **Save**.

---

## 3. Copy the client credentials into `.env`

In the client → **Credentials** tab → copy the **Client secret**. Then, in the
project's section of the **root `.env`** (NEVER commit it), set the per-project
slots the generator already created:

```dotenv
# >>> PROJECT: happy-teeth >>>
HAPPY_TEETH_APP_SECRET=<a strong random string>          # encrypts the session cookie
HAPPY_TEETH_OIDC_CLIENT_ID=happy-teeth                    # the Client ID from step 2
HAPPY_TEETH_OIDC_CLIENT_SECRET=<the Client secret>        # from the Credentials tab
```

(`scripts/generate-secrets.sh` can fill `*_APP_SECRET` for you; the client id/secret
come from Keycloak.)

---

## 4. (Optional but recommended) audience mapper

By default a Keycloak access token's `aud` may not include your client id, so the
backend leaves audience validation **off** (it still validates issuer + signature +
lifetime). To validate audience too:

1. Client → **Client scopes** → `happy-teeth-dedicated` → **Add mapper** → **By
   configuration** → **Audience**.
2. **Included Client Audience**: `happy-teeth` → **Save**.
3. Set `OIDC_AUDIENCE=happy-teeth` in `.env` (or leave it blank to let the backend
   default to the client id, which now matches).

---

## 5. Turn auth on

In the **root `.env`**, set the realm issuer (shared across projects in this realm):

```dotenv
OIDC_ISSUER_URL=https://auth.example.com/realms/pi
# OIDC_AUDIENCE=happy-teeth          # optional (see step 4)
# OIDC_REDIRECT_URI / OIDC_POST_LOGOUT_REDIRECT_URI: leave blank to use the
#   subdomain-derived defaults registered in step 3.
```

Then (re)start the project so it picks up the env:

```bash
./scripts/project.sh up happy-teeth
# ensure Caddy is up:  ./scripts/start-proxy.sh
```

Visit `https://teeth.example.com/account` → you should be redirected to Keycloak,
log in, and land back on the protected page. `GET /api/me` on the backend now
requires a valid Bearer token.

---

## Local `*.localhost` testing (internal CA)

A public deployment uses Let's Encrypt certs (trusted), so the frontend/backend can
fetch the realm metadata + JWKS normally. For **local** testing behind Caddy's
**internal CA**, those TLS certs aren't trusted by Node/.NET. For that case only:

- Backend: `OIDC_REQUIRE_HTTPS_METADATA=false` in `.env`.
- Frontend: add `NODE_TLS_REJECT_UNAUTHORIZED=0` to the web service's environment
  (in `services/<name>/<name>.compose.yml`).

**Never set these in production.** The cleaner alternative is to test against a real
public deployment (Cloudflare Tunnel + Let's Encrypt — see
`docs/cloudflare-tunnel.md`).

---

## Multiple projects, one realm

Repeat **steps 2–3** per project (a client each, with that project's subdomain
URLs and its own `*_OIDC_CLIENT_ID/_SECRET`). `OIDC_ISSUER_URL` (step 5) is shared.
Users in the realm can then sign in to any project that has a client.
