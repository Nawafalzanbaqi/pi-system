# __PROJECT_NAME__ — full-stack (Next.js + .NET)

Scaffolded for **pi-system** from the `fullstack` template on __GENERATED_DATE__.

Two cooperating services in one project:

| Part                    | Tech     | Networks            | Exposure                              |
| ----------------------- | -------- | ------------------- | ------------------------------------- |
| `__PROJECT_NAME__-api`  | .NET API | `internal`          | internal-only (no host ports, no proxy) |
| `__PROJECT_NAME__-web`  | Next.js  | `internal` + `proxy`| Caddy at `__SUBDOMAIN__.<BASE_DOMAIN>` |

- The **frontend** calls the **backend** server-side over the internal network
  at `http://__PROJECT_NAME__-api:8080` (`BACKEND_URL`) — the API is never
  exposed to the browser or the outside world directly.
- The **backend** connects to the `__DB_ENGINE__` database (service
  `__DB_HOST__`) via `ConnectionStrings__Default`, built from the shared DB
  credentials in `.env`.
- Layout on disk: `backend/` (.NET) and `frontend/` (Next.js).

## Run on the platform

```bash
./scripts/db.sh __DB_ENGINE__ up        # start the database (skip if "none")
./scripts/start-proxy.sh                # ensure Caddy is up
./scripts/project.sh up __PROJECT_NAME__   # builds + starts api and web
```

Then browse `https://__SUBDOMAIN__.<BASE_DOMAIN>` — the page shows the backend's
`/api/info` response, proving the internal frontend→backend→DB wiring.

## Put it behind Keycloak (later)

Create a confidential client in your Keycloak realm (at `auth.<BASE_DOMAIN>`) and
set `__ENVPREFIX__OIDC_CLIENT_ID` / `__ENVPREFIX__OIDC_CLIENT_SECRET` in `.env`.
Guard the frontend (e.g. NextAuth) and validate the issued tokens in the API,
both pointed at `https://auth.<BASE_DOMAIN>/realms/<realm>`.
