# Package cache (`services/cache`)

An **optional, profile-gated** local cache for **npm** and **NuGet**, so repeated
dependency installs on the Pi are faster (and keep working on a flaky link). Both
registries transparently **mirror + cache the public registries**, so a project
gets every public package the first time and from the local cache thereafter.

> Both services sit behind the Compose **`cache` profile**, so they **never
> auto-start** and consume **zero RAM until you run `./scripts/cache.sh up`**.
> When the cache is down, projects fall back to the public registries.

## What's inside

| Service | Image (pinned, arm64) | Network | Reached as | Mem |
| ------- | --------------------- | ------- | ---------- | --- |
| `verdaccio`   | `verdaccio/verdaccio:6.7.1` | `internal` + `proxy` | `http://verdaccio:4873/` (UI: `cache.${BASE_DOMAIN}`) | 256M |
| `nuget-cache` | `bagetter/bagetter:1.6.5`   | `internal` only      | `http://nuget-cache:8080/v3/index.json` | 384M |

- **Verdaccio** proxies/caches `registry.npmjs.org`. Its web UI is the only thing
  exposed, and only through **Caddy** (no host ports). Config is the committed,
  secret-free [`verdaccio/config.yaml`](verdaccio/config.yaml); cached tarballs
  persist in the `verdaccio_storage` volume.
- **`nuget-cache`** is **BaGetter**, a lightweight NuGet server run in
  read-through **mirror** mode against `nuget.org`. It is **internal-only** (no
  UI exposed); its SQLite index + package files persist in `nuget_cache_data`.

### Why BaGetter (and not just a folder, or BaGet/SonarType/etc.)

The task's two options were a lightweight ARM64 NuGet server **or** a shared
local folder source. We ship **BaGetter** — the actively-maintained, multi-arch
(arm64) fork of BaGet — because, unlike a plain folder, it **mirrors nuget.org
read-through**: projects keep restoring *any* public package with no manual
copying, while still caching locally. It is far lighter than Nexus/Artifactory
(those are JVM-heavy and ARM-unfriendly — the same reason we avoid SonarQube for
the quality gate). It is still **profile-gated**, so it costs nothing when idle.

> Truly want zero containers? A **shared NuGet folder source** also works: mount
> one host directory into your SDK containers and add it as a `<add key=... value=
> "/path" />` source. It only caches packages you place there by hand (no
> read-through mirror), so it suits offline/air-gapped use more than day-to-day
> speed-ups — hence BaGetter is the default. See docs/README.md "Package cache".

## Run it

```bash
./scripts/cache.sh up        # start verdaccio + nuget-cache (profile: cache)
./scripts/cache.sh status    # show their status
./scripts/cache.sh logs      # follow logs (cache hits/misses)
./scripts/cache.sh down      # stop + remove the containers (caches are KEPT)
```

The Verdaccio UI is at `https://cache.${BASE_DOMAIN}` once Caddy is up
(`./scripts/start-proxy.sh`).

## How a project opts in

Opting in is **optional and never forced**. Two ways:

1. **Generator flag (writes the config files for you):**
   ```bash
   ./scripts/new-project.sh --name acme --preset clinic --cache
   ```
   This drops the right opt-in file(s) into the new project:
   - a frontend **`.npmrc`** → `registry=http://verdaccio:4873/`
   - a backend **`nuget.config`** → a single `pi-cache` source pointing at
     `http://nuget-cache:8080/v3/index.json`

   (Placed at the project root for `nextjs-app`/`dotnet-api`, and under
   `frontend/` + `backend/` for `fullstack`.) These are copied from
   [`optin/.npmrc`](optin/.npmrc) and [`optin/nuget.config`](optin/nuget.config),
   which you can also copy by hand.

2. **Env / CLI per install (graceful auto-fallback, no committed file):**
   ```bash
   npm_config_registry=http://verdaccio:4873/ npm ci
   dotnet restore --source http://nuget-cache:8080/v3/index.json
   ```
   When the var/flag is absent, the public registries are used automatically.

### ⚠ The build-network note

A committed `.npmrc` / `nuget.config` is a **hard opt-in**: while present, the
project will use the cache, so the cache must be **up** *and* the install must
run somewhere that can resolve `verdaccio` / `nuget-cache` — i.e. on the
**`internal`** Docker network. `docker compose build` runs in an **isolated
build network by default**, so to use the cache at *image-build* time, build with
the internal network — Compose Spec `build.network`:

```yaml
# in services/<name>/<name>.compose.yml, under the service's build:
build:
  context: .
  network: ${INTERNAL_NETWORK_NAME:-pi_internal}   # lets npm/dotnet reach the cache
```

(Requires the base stack to be up so the network exists.) If you don't want that
coupling, prefer the **env/CLI** method above (graceful fallback) and let the
cache speed up host-side and `compose run` installs. To stop using the cache,
just **delete** the `.npmrc` / `nuget.config` (or regenerate without `--cache`).

## Publishing your own packages (optional)

Both are also private feeds:

- **npm:** self-registration is disabled in `config.yaml`. Add a user once via
  htpasswd, e.g.
  `docker exec -it pi-system_verdaccio sh -c 'apk add --no-cache apache2-utils 2>/dev/null; htpasswd -Bb /verdaccio/storage/htpasswd <user> <pass>'`,
  then `npm login --registry http://verdaccio:4873/` and `npm publish`.
- **NuGet:** set `NUGET_CACHE_API_KEY` in `.env` (PACKAGE CACHE section), restart
  the cache, then `dotnet nuget push -s http://nuget-cache:8080/v3/index.json -k <key>`.

Neither is required for the cache use-case (installs are anonymous).
