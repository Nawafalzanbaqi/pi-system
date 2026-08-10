# hello-module — reference module

The smallest module that follows the [module contract](../README.md) end to end.
It is intentionally **safe and minimal**: it contributes **only empty env
templates** — no container, no Caddy route, no database, no external credentials.
That makes it the perfect copy-paste starting point and a way to verify the
generator's module pipeline without standing up any infrastructure.

## What it declares

See [`module.manifest`](module.manifest):

- `status: implemented` — so the generator actually composes it in.
- `database: none`, `external_credentials: none`, `compose: none`,
  `caddy_routes: none` — nothing to stand up.
- `env: HELLO_MODULE_ENABLED, HELLO_MODULE_GREETING` — two empty templates,
  mirrored in [`env.example`](env.example).

## What happens when you add it

```bash
./scripts/new-project.sh --name demo --base nextjs-app --db none \
  --subdomain demo --modules hello-module
```

The generator:

1. Appends `HELLO_MODULE_ENABLED=` and `HELLO_MODULE_GREETING=` (blank) to the
   `demo` section of `.env.example`, labelled `(module: hello-module)`.
2. Records `hello-module` under **Active modules** in `services/demo/PROJECT.md`.

That's it — a clean demonstration of manifest parsing and env injection.

## Turning this into a real module

Give it a job by filling in the parts this reference leaves empty:

- Run a service → add a `service.compose.yml` fragment and point `compose:` at it
  (ARM64, pinned tag, **no host ports**, mem limit, `no-new-privileges`,
  `internal`/`proxy` networks; name the service `__PROJECT_NAME__-hello`).
- Expose HTTP under the project's subdomain → add a `caddy.snippet` and point
  `caddy_routes:` at it (path routes only, no new host ports).
- Need data → set `database:` to the engine and read it via the injected DB env.
- Need an external account → describe it in `external_credentials:` so the
  generator warns the operator in `PROJECT.md`.
