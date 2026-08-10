# __PROJECT_NAME__ — .NET Web API

Scaffolded for **pi-system** from the `dotnet-api` template on __GENERATED_DATE__.

- **Runtime:** .NET (current LTS), minimal Web API, containerized multi-stage for ARM64.
- **Database:** `__DB_ENGINE__` — reached on the `internal` network as `__DB_HOST__`.
  The connection string is injected as `ConnectionStrings__Default` by
  `__PROJECT_NAME__.compose.yml`, built from the shared DB credentials in `.env`.
- **Networking:** no host ports. Caddy fronts it at `__SUBDOMAIN__.<BASE_DOMAIN>`.
- **Endpoints:** `GET /health` (liveness) and `GET /` (reports DB-configured status).

## Develop

```bash
dotnet run        # local dev (reads ConnectionStrings__Default from your env)
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
Wire OIDC auth in `Program.cs` against `https://auth.<BASE_DOMAIN>/realms/<realm>`.
