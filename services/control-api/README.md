# control-api — the web control panel (UI + API)

Next.js service that serves **both** the panel UI (App Router pages under `app/`
+ `components/`) **and** its API (route handlers under `app/api`) on the same
origin. It lets you (A) monitor/control the platform and (B) manage integration
credentials in `.env`, from a calm, bilingual (Arabic-RTL primary), light/dark
browser panel. ARM64, version-pinned, on `internal` + `proxy`, **no host ports**,
reached only via Caddy at `https://api.${BASE_DOMAIN}`. Full docs:
`docs/README.md` → **Control panel**.

> **Part #1** = the secure API. **Part #2** = the UI ported onto it + browser OIDC
> login (BFF, httpOnly session) + live wiring. Charts use **recharts**, animation
> **framer-motion**, fonts are self-hosted via `next/font`; design tokens
> (`components/theme.js`) are the single source of truth.

## Security at a glance

- **Keycloak JWT on every endpoint except `GET /api/health`** (issuer + audience +
  JWKS). No/invalid token → 401.
- **Operator role required for all writes/actions/config-changes.** Valid token,
  no role → 403. Fails closed when OIDC is unconfigured.
- **No Docker socket.** Control + restart actions run on the host **only** through
  the audited `scripts/bot-exec.sh` bridge over SSH (a dedicated forced-command
  key) — the same constrained path the Telegram bot uses. Action ARGV is always an
  array spawned with `execFile`; no shell ever sees a value.
- **Config manager is allowlist-only** (`config-registry.json`): only listed `.env`
  keys are readable/writable; **secret values are never returned** (set/empty/
  masked); writes back up `.env` first, are atomic, and preserve structure;
  **values are never logged**. Every change is audit-logged (key + identity +
  result, never the value).

## Layout

```
config-registry.json     the allowlist: editable .env keys grouped by integration
lib/                     pure logic (ESM) + thin seams — raw-node testable:
  registry.js            allowlist + value-shape validation + masking
  env.js                 parse/get/set .env (string in/out) + integration summary
  env-writer.js          safe writer: backup + atomic write (fs seam)
  auth-core.js           bearer parse + role check + 401/403/200 decision (no jose)
  verify-token.js        SEAM: jose JWKS signature/issuer/audience check
  authorize.js           bearer OR httpOnly session cookie -> verify-token + auth-core
  bridge-core.js         action allowlist + argv builder + restart whitelist
  bridge.js              SEAM: SSH forced-command transport (execFile, no shell)
  actions.js             validate -> bridge -> audit, returns JSON
  config.js http.js audit.js ratelimit.js
  auth/oidc.js           browser OIDC RP (openid-client, PKCE) — server-side
  auth/session-core.js   PURE: seal/unseal the httpOnly JWE session cookie (jose)
  auth/session.js        request-scoped session reads (next/headers)
  api-client.js          PURE request shaping (buildRequest) + fetch wrapper
  adapt.js               host text|JSON -> structured status/health/projects
  wizard-payload.js      wizard selections -> exact generate payload + command
  panel-gate.js          PURE UI route-guard decision (no session -> login)
  integrations-view.js   PURE: a secret value is never displayable
  confirm-machine.js     PURE confirm->pending->success|error reducer
app/api/                 API route handlers (UNCHANGED from part #1): health,
                         status, system-health, projects, checks,
                         integrations[, /{key}], actions/{action}, actions/restart-service
app/api/auth/            BFF OIDC: login, callback, session, logout
app/layout.jsx page.jsx  panel UI (root layout + guarded entry: AppShell | LoginGate)
app/globals.css          document-level styles (reset, fonts, keyframes, RTL)
components/              ported design system: theme.js (TOKENS) · strings.js ·
                         catalog.js · primitives.jsx · charts.jsx (recharts) ·
                         states.jsx · Sidebar/TopBar/AppShell/LoginGate ·
                         sections/{Overview,Projects,Monitoring,Growth,Settings}
Dockerfile               multi-stage, node:22-alpine, standalone, non-root, healthcheck
control-api.compose.yml  internal+proxy, no host ports, 256M, scoped .env mount
```

## Run

```
./scripts/control-api.sh up        # build + start (ensure Caddy is up)
./scripts/control-api.sh status    # / logs / down
```

See `docs/README.md` → **Control API** for the deferred one-time setup (Keycloak
client, SSH bridge key, container UID) and the endpoint reference.
