# __PROJECT_NAME__ — Next.js app

Scaffolded for **pi-system** from the `nextjs-app` template on __GENERATED_DATE__.

- **Runtime:** Next.js (App Router, standalone output), containerized multi-stage for ARM64.
- **Config:** read from environment variables. `DATABASE_URL` (for the
  `__DB_ENGINE__` engine, reached as `__DB_HOST__`) is injected by
  `__PROJECT_NAME__.compose.yml`, built from the shared DB credentials in `.env`.
- **Networking:** no host ports. Caddy fronts it at `__SUBDOMAIN__.<BASE_DOMAIN>`.
- **Endpoints:** `GET /` (home) and `GET /health` (liveness).

## Develop

```bash
npm install
npm run dev       # http://localhost:3000
```

## Run on the platform

```bash
./scripts/db.sh __DB_ENGINE__ up        # start the database (skip if "none")
./scripts/start-proxy.sh                # ensure Caddy is up
./scripts/project.sh up __PROJECT_NAME__
```

Then browse `https://__SUBDOMAIN__.<BASE_DOMAIN>` (e.g. `https://__SUBDOMAIN__.localhost`).

## Put it behind Keycloak (later)

Create a confidential client in your Keycloak realm (at `auth.<BASE_DOMAIN>`) and
set `__ENVPREFIX__OIDC_CLIENT_ID` / `__ENVPREFIX__OIDC_CLIENT_SECRET` in `.env`
(the compose fragment passes them in as `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET`).
Use an OIDC client library (e.g. NextAuth) pointed at
`https://auth.<BASE_DOMAIN>/realms/<realm>`.
