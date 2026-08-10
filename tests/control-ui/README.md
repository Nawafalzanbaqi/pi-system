# tests/control-ui — control-panel UI logic suite (offline)

Pure-logic tests for the panel's browser layer (control-panel **part #2**). They
run with **no Docker, no browser and no network** — they import the dependency-free
UI logic modules directly and assert behaviour, then do a few static repo checks.

```
./tests/control-ui/run.sh        # exits non-zero on any failure
```

## What it proves

1. **`ui.test.mjs` (node)** — imports only React-free, framework-free modules:
   - **API client request shaping** (`lib/api-client.js`) — correct method, path,
     body serialization, JSON content-type only when there's a body, cookie
     credentials, and **`Authorization: Bearer` attached when a token is given**.
   - **Auth-guard decision** (`lib/panel-gate.js`) — no session → `login`, a
     session with a subject → `app`, operator flag carried.
   - **Secrets never rendered** (`lib/integrations-view.js`) — `displayableKeyValue`
     returns `null` for any secret key (even a malicious fixture carrying a value),
     and `secretValueLeaks` flags a value-on-secret or a non-bullet mask.
   - **Action state machine** (`lib/confirm-machine.js`) — `confirm → pending →
     success | error`, retry from error, and the derived view flags.
   - **Wizard payload builder** (`lib/wizard-payload.js`) — selections → the exact
     generate payload + `scripts/new-project.sh` command, with validation.
   - **Live-data adapters** (`lib/adapt.js`) — structured pass-through + tolerant
     parse of the host's text `status`/`projects`/`system-health` output.

2. **Static checks (bash)** — the prototype scaffolding (CDN React / Babel /
   artboards) was dropped, fonts are self-hosted (no `fonts.googleapis.com`), the
   `/api/auth/session` endpoint never returns tokens, the session cookie is
   `httpOnly` + `SameSite=Lax`, the Settings view renders values only through the
   secret-safe helper, no token is cached in `localStorage`, and the new deps
   (`framer-motion`, `recharts`, `openid-client`) are pinned to exact versions.

The final gate (run manually / in CI) is a real `next build` of the merged app,
which compiles the UI pages + components alongside the unchanged API routes.

The part-#1 API suite ([`tests/control-api`](../control-api/)) stays green and is
unchanged.
