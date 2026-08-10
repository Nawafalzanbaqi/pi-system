# Dashboard — Homepage

A single landing page that fronts every platform service with cards, links and
at-a-glance health. It is [gethomepage/homepage](https://gethomepage.dev/), a
lightweight, file-configured dashboard.

| | |
|---|---|
| **Image** | `ghcr.io/gethomepage/homepage:v1.13.1` (multi-arch, incl. `linux/arm64`) |
| **Internal port** | `3000` |
| **Networks** | `proxy` (Caddy fronts it) + `internal` (health probes reach services by name) |
| **Host ports** | none — reachable only via Caddy at `home.${BASE_DOMAIN}` |
| **Memory limit** | 256M |
| **Compose** | [`dashboard.compose.yml`](dashboard.compose.yml) |
| **Helper** | [`../../scripts/dashboard.sh`](../../scripts/dashboard.sh) `up\|down\|logs\|status` |

## Configuration lives in a mounted directory (not a named volume)

Homepage's whole configuration is the committed YAML under
[`config/`](config/), bind-mounted to `/app/config`:

```
config/
├── settings.yaml    Title, theme, group layout
├── services.yaml    The service cards (links + secret-free HTTP health)
├── widgets.yaml     Top info widgets (search, clock, resources)
├── bookmarks.yaml   Quick links
└── docker.yaml      Docker-socket integration (DISABLED by default)
```

A mounted directory was chosen over a named volume **on purpose**: the dashboard
layout is part of the repository, so it is version-controlled, reviewable in a
diff, and edited in place. After editing, run `./scripts/dashboard.sh up`
(or just refresh — Homepage re-reads the YAML per request).

## No secrets, ever

Nothing in `config/` contains a secret. Service URLs are built at runtime from
`${BASE_DOMAIN}` via Homepage's `{{HOMEPAGE_VAR_BASE_DOMAIN}}` substitution, so
the same files work locally (`home.localhost`) and in production
(`home.your-domain`). Any widget that needs an API key (e.g. the optional
Portainer widget) reads it from a `HOMEPAGE_VAR_*` variable in the root `.env`
— see the `DASHBOARD (Homepage)` section of `.env.example`. Those widgets ship
**commented out** until a key is provided.

## Host validation

Since v1.0 Homepage refuses requests whose `Host` header is not in
`HOMEPAGE_ALLOWED_HOSTS`. The compose file sets it to `home.${BASE_DOMAIN}`
automatically (`localhost:3000` is always allowed too), so it tracks your domain
with no manual step.

## Adding a generated project

Projects scaffolded by `scripts/new-project.sh` are published at
`https://<subdomain>.${BASE_DOMAIN}`. Add a card under the **Projects** group in
[`config/services.yaml`](config/services.yaml) — there is a commented example to
copy.
