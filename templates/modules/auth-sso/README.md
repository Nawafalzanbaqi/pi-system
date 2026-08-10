# auth-sso — single sign-on via the platform's Keycloak

`auth-sso` is the **optional** module that puts a generated project behind the
platform's existing **Keycloak** identity provider (already running at
`auth.${BASE_DOMAIN}`). It implements **real OIDC**:

- **Frontend (Next.js):** the **Authorization Code flow with PKCE**, an encrypted
  session cookie, `login` / `logout` / `callback` routes, a read-only session
  probe, and a **protected route** example.
- **Backend (.NET):** **JWT bearer validation** against the realm — issuer,
  audience and signing key (via the realm's JWKS) — plus an example protected
  endpoint (`GET /api/me`).

It is **composable, never forced**: a public marketing site (`company-site`) needs
no login and does not get this module; an admin context (`clinic`, `real-estate`)
does. It needs **no new external service** — Keycloak already exists — and **no
secrets in committed files** (every key/URL is an empty `.env` template). The only
manual step is a one-time, operator-run Keycloak console action, documented in
[`SETUP.md`](SETUP.md) and **deferred to the final manual session**.

> Use the existing Keycloak. This module does **not** stand up a new identity
> service or change Keycloak's running deployment.

---

## How the flow works

```
                 ┌───────────────────────── browser ─────────────────────────┐
   1. GET /account ─▶ (no session) ─▶ 302 /api/auth/login?returnTo=/account
   2. /api/auth/login  ── builds PKCE verifier+challenge, state, nonce ──┐
                         seals them in a short-lived cookie, 302 ───────▶│
   3. Keycloak  authorize  (auth.${BASE_DOMAIN}/realms/<realm>) ─ user logs in ─┐
   4. 302 back to  /api/auth/callback?code=…&state=…  ◀───────────────────────┘
   5. /api/auth/callback ── verify state, exchange code + code_verifier for
                            tokens, validate id_token (JWKS/nonce/aud/exp/iss),
                            seal an encrypted session cookie, 302 /account
   6. /account renders; server-side it calls the backend GET /api/me with the
      access token ──▶ .NET resource server validates the JWT (issuer/aud/JWKS) ─▶ 200
   7. /api/auth/logout ── clear session, 302 Keycloak end-session ──▶ post-logout URL
                 └────────────────────────────────────────────────────────────┘
```

- **PKCE** protects the code exchange; **state** prevents CSRF on the callback;
  **nonce** binds the id_token to this login. All three are sealed in a
  short-lived (`pi_auth_tx`) cookie and consumed once.
- The **session** (`pi_session`) is a **JWE (AES-256-GCM)** sealed with the
  project's `APP_SECRET` — the browser cannot read or tamper with it. It holds the
  user's claims plus the id/access tokens (the access token is forwarded to the
  backend server-side; it never reaches the browser).

---

## Per-base behaviour

`base_compatible: all`, but each base gets the half that makes sense (per-base
`files/` + per-base `compose/` fragments):

| Base         | Frontend (Auth Code + PKCE) | Backend (JWT validation) | Notes |
| ------------ | --------------------------- | ------------------------ | ----- |
| `nextjs-app` | ✅ login + protected page    | — (no backend of its own) | Talks to a separate API if you wire one (`BACKEND_URL`). |
| `dotnet-api` | — (a separate client logs in) | ✅ resource server + `/api/me` | The API trusts Bearer tokens from any client in the realm. |
| `fullstack`  | ✅ in the frontend           | ✅ in the backend         | The end-to-end shape used by `clinic` / `real-estate`. |

When one half is absent it is a **documented integration point**, not a broken
reference: a `nextjs-app` with no backend simply shows "no backend wired"; a
`dotnet-api` exposes a protected endpoint for whatever client drives the login.

---

## How the generator wires it

Standard module composition (see [`../README.md`](../README.md)), plus the two
mechanisms this module relies on:

1. **Per-base `compose/` fragment.** `compose: compose` names a *directory*; the
   generator copies `compose/<base>.compose.yml` to
   `services/<name>/<name>.auth-sso.compose.yml` (loaded by `scripts/project.sh`).
   It adds **no container and no host ports** — it only **merges OIDC environment**
   into the project's existing service(s) (Compose merges `environment` maps), and
   derives the redirect / post-logout URLs from the project's **subdomain** +
   `${BASE_DOMAIN}`.
2. **Per-base `files/` tree.** The Next.js OIDC client (`nextjs-app`, `fullstack`
   frontend) and the .NET resource server (`dotnet-api`, `fullstack` backend).

### Environment

The generator already appends **per-project** OIDC slots to every project's
`.env.example` (regardless of this module): `<PREFIX>_OIDC_CLIENT_ID`,
`<PREFIX>_OIDC_CLIENT_SECRET`, `<PREFIX>_APP_SECRET`. **auth-sso reuses those** for
the per-project client credentials and session key — it does **not** duplicate
them. Its own `env:` templates add only what the base lacks:

| Variable | Scope | Set it? |
| -------- | ----- | ------- |
| `OIDC_ISSUER_URL` | realm-level (one realm can serve many projects) | **Yes** — the realm URL. Blank ⇒ auth OFF. |
| `OIDC_AUDIENCE` | per token | Optional — defaults to the project's client id. |
| `OIDC_REDIRECT_URI` | per project | Optional — derived from the subdomain. |
| `OIDC_POST_LOGOUT_REDIRECT_URI` | per project | Optional — derived from the subdomain. |
| `<PREFIX>_OIDC_CLIENT_ID` / `_SECRET` | per project | **Yes** — from the Keycloak client (base's slots). |
| `<PREFIX>_APP_SECRET` | per project | **Yes** — encrypts the session cookie. |

> **Why reuse the base slots instead of declaring global `OIDC_CLIENT_ID`?** The
> base ships generic, per-project OIDC hooks precisely for this module. Reusing
> them keeps the **credentials per-project** (two projects on one Pi don't
> collide) and avoids a confusing duplicate (`CLINIC_OIDC_CLIENT_ID` *and* a
> global `OIDC_CLIENT_ID`) in the same `.env`. The realm-level `OIDC_ISSUER_URL`
> is shared across projects, so it stays a single global value.

**Fail-closed by design:** with `OIDC_ISSUER_URL` blank, the frontend `/api/auth/*`
routes return **503** and the backend's protected endpoint returns **503** — the
rest of the app keeps working. Nothing is ever silently left open.

---

## How it composes with other modules

- **i18n-bilingual.** Route protection uses a **server-side guard in the route
  segment's layout** (`requireSession()`), **not** Next.js middleware — because
  i18n already owns `middleware.js` (one per app) and a competing auth middleware
  would collide. The protected page ships at **both** `/account` and
  `/<locale>/account` (the same trick `bookings` uses for `/booking`), and all
  auth routes live under `/api/auth/*`, which the i18n middleware already skips. So
  login, logout and protection all work whether or not i18n is composed.
- **bookings.** `bookings` **owns** the backend `Program.cs` and `app.csproj`.
  auth-sso is **fully additive** on the .NET side and never replaces them:
  - `Auth/OidcHostingStartup.cs` is an `[assembly: HostingStartup]` that registers
    JWT validation + the protected endpoint. It is activated by
    `ASPNETCORE_HOSTINGSTARTUPASSEMBLIES=app` (set in the compose fragment), so it
    runs *in addition to* whatever `Program.cs` the project has (base or bookings').
  - `Directory.Build.props` adds the `Microsoft.AspNetCore.Authentication.JwtBearer`
    package via MSBuild auto-import — so it does not touch `app.csproj` (bookings'
    Npgsql reference still applies).

  Result: a `clinic` composes `bookings` + `content-admin` + `i18n-bilingual` +
  `auth-sso` together with **no file collisions**.

- **content-admin.** Independent: Directus is internal-only with its own admin; it
  is unaffected by app-level SSO. Its files are additive (`lib/directus.js` /
  `DirectusClient.cs`) and do not overlap auth-sso's.

---

## The one-time manual Keycloak step (deferred)

Creating a realm and a **confidential client per project** (with the exact redirect
URIs derived from the project's subdomain) is a console action that cannot be done
safely from code — it is **operator-run, once**, during the **final manual
session**. The generated project **builds and is correct without it**; it simply
reports 503 on the auth endpoints until the realm + client exist and the values are
in `.env`. Full, copy-pasteable steps (with values derived from your subdomain and
`BASE_DOMAIN`) are in **[`SETUP.md`](SETUP.md)**.

Code (automatic) vs Keycloak console (manual, later):

| Automatic (generator / code) | Manual (operator, Keycloak console, once) |
| ---------------------------- | ----------------------------------------- |
| OIDC client code (frontend + backend) | Create / choose a **realm** |
| Compose env wiring + derived redirect URIs | Create a **confidential client** per project |
| Empty `.env` templates | Paste the **client id + secret** into `.env` |
| JWT validation against the realm JWKS | Add an **audience mapper** (optional) |

---

## Local testing caveat (internal CA)

Against a public deployment (Cloudflare Tunnel + Let's Encrypt) this "just works":
the frontend and backend reach the realm at its public HTTPS URL with a trusted
cert. For **local `*.localhost`** testing behind Caddy's **internal CA**, the
realm's TLS cert is not trusted by Node/.NET, so metadata/JWKS fetches fail. For
that case only, set `OIDC_REQUIRE_HTTPS_METADATA=false` (backend) and, if needed,
`NODE_TLS_REJECT_UNAUTHORIZED=0` on the web container — **never in production**. See
[`SETUP.md`](SETUP.md).

---

## Idiomatic backend variant (when you own `Program.cs`)

The shipped resource server adds its protected endpoint via terminal middleware so
it can stay additive (composing with bookings). If you have a plain `dotnet-api`
project where **you** own `Program.cs` (no bookings), the idiomatic minimal-API
form is equivalent — register the same JwtBearer options, then:

```csharp
app.UseAuthentication();
app.UseAuthorization();
app.MapGet("/api/me", (ClaimsPrincipal user) => Results.Ok(new {
    sub = user.FindFirst("sub")?.Value,
    name = user.Identity?.Name,
})).RequireAuthorization();
```

---

## Files in this module

```
auth-sso/
├── module.manifest        # status: implemented; base_compatible: all; compose: compose
├── env.example            # OIDC_ISSUER_URL, OIDC_AUDIENCE, redirect/post-logout
├── README.md              # this file
├── SETUP.md               # the one-time, operator-run Keycloak steps (deferred)
├── compose/               # per-base env-merge fragments (no new container/ports)
│   ├── nextjs-app.compose.yml
│   ├── dotnet-api.compose.yml
│   └── fullstack.compose.yml
└── files/
    ├── nextjs-app/        # Next.js OIDC client (Auth Code + PKCE)
    │   ├── package.json   #   + openid-client@5.7.1, jose@5.10.0 (pinned, pure-JS)
    │   ├── lib/auth/{oidc,session,guard,api}.js
    │   ├── app/api/auth/{login,callback,logout,session}/route.js
    │   ├── app/account/{layout,page}.jsx            # protected (no-middleware guard)
    │   ├── app/[locale]/account/{layout,page}.jsx   # i18n-cooperating variant
    │   └── components/AuthStatus.jsx
    ├── fullstack/
    │   ├── frontend/      # identical to nextjs-app, under frontend/
    │   └── backend/       # additive .NET resource server
    │       ├── Directory.Build.props   # adds JwtBearer (no app.csproj edit)
    │       └── Auth/OidcHostingStartup.cs
    └── dotnet-api/        # additive .NET resource server
        ├── Directory.Build.props
        └── Auth/OidcHostingStartup.cs
```
