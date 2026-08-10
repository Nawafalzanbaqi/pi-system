# Automation workflows

Importable n8n workflows for the platform. These are **exported JSON** — n8n
does **not** auto-load them. Import each one manually (below) after the
automation stack is up (`./scripts/automation.sh up`).

---

## `platform-health-alert.json` — platform health monitor + alert

A self-contained, internal-operations workflow that watches the platform and
raises an alert when something is down. No scraping, no third-party data — just
health checks of your own services.

### What it does

```
Schedule Trigger ──▶ Check platform services ──▶ Any service down? ──┬─(true)─▶ Send alert (configure me)
   every 5 min          (HTTP health checks)          (IF)            └─(false)▶ All healthy
```

1. **Schedule Trigger** fires every 5 minutes.
2. **Check platform services** (a Code node) makes an internal HTTP request to
   each service in its `TARGETS` list and marks each healthy/unhealthy. Because
   n8n runs on the `internal` + `proxy` Docker networks, it reaches services by
   their **service name** (e.g. `http://uptime-kuma:3001`) — no host ports
   needed. It also `console.log`s the result, so the n8n execution log /
   `./scripts/automation.sh logs` is a zero-config alert channel on its own.
3. **Any service down?** (an IF node) branches on whether any check failed.
4. On failure → **Send alert (configure me)**; otherwise → **All healthy**.

Default `TARGETS` are the always-on management services (Uptime Kuma, Portainer).
Edit the list in the Code node to add your own apps. Note: on-demand services
that are intentionally stopped will register as **down** — that is expected.

### Import it

1. Open n8n at `https://automation.<BASE_DOMAIN>` (locally:
   `https://automation.localhost`) and log in.
2. Top-right **⋮ menu → Import from File** (or **Workflows → Import from File**).
3. Choose `automation/workflows/platform-health-alert.json`.
4. **Save**, then toggle it **Active** (top-right) so the schedule runs. You can
   also hit **Test workflow** once to see it run immediately.

### Make it actually notify you (no secrets in git)

Out of the box the alert step is a **no-op** (safe default) and the only signal
is the logged line. To get real notifications, replace the
**Send alert (configure me)** node with one of:

| Channel | Node to add | What to configure |
|---|---|---|
| Telegram | **Telegram** | a Telegram API credential (bot token) + your chat id |
| Email | **Send Email** | an SMTP credential |
| Slack / Discord / generic | **HTTP Request** (POST) | the incoming-webhook URL |

Keep every token / webhook URL in an n8n **credential** or **environment
variable** (e.g. reference `={{ $env.ALERT_WEBHOOK_URL }}` in an HTTP Request
node and set `ALERT_WEBHOOK_URL` in your `.env` for the n8n service). **Never**
hard-code a secret into the workflow — this JSON is committed to git.

A useful alert body is the list of failed checks: `={{ $json.failures }}`.

The imported workflow also carries a **sticky note** repeating these swap
instructions, so the editor is self-documenting.

### Share the Telegram management bot's channel (no secrets in git)

This workflow ships a **disabled** node — *Notify Telegram (optional — enable
me)* — already wired to the **true** (failure) branch. Enable it to make health
alerts land in the **same** chat you control the platform from via
[`telegram-management-bot.json`](#telegram-management-botjson--telegram-management-bot),
so **alerts and control share one channel**:

1. Right-click the node → **Enable**.
2. Select your **Telegram API** credential (the same BotFather token).
3. It sends to the first id in `TELEGRAM_ALLOWED_IDS` (read as `$env`) and embeds
   **no** secret. The bot token stays in the n8n credential; the allowlist stays
   in `.env`.

### Tune it

- **Which services:** edit the `TARGETS` array in the Code node.
- **How often:** edit the **Schedule Trigger** node (default every 5 min).
- **Alternative source:** instead of direct HTTP checks you can point a check at
  Uptime Kuma's API (e.g. a status-page/heartbeat endpoint) if you prefer Uptime
  Kuma to own the probing — the swappable structure stays the same.

---

## `telegram-management-bot.json` — Telegram management bot

A lightweight, **operator-only** bot that lets you monitor and control the
platform from Telegram — receive alerts, query status, and trigger a **safe,
whitelisted** set of actions. It is implemented entirely as an n8n workflow plus
a thin, audited host bridge ([`scripts/bot-exec.sh`](../../scripts/bot-exec.sh));
**no new always-on container and no paid AI** — every command is deterministic.

### What it does

```
Telegram Trigger → Authorize, parse & plan → Execute on host? ─┬─(true)→ Run bot-exec.sh (SSH) → Reply: command result
   (your bot)        (allowlist + whitelist)                   └─(false)→ Reply: message (denial / help / unknown / error)
```

1. **Telegram Trigger** receives a message from your bot.
2. **Authorize, parse & plan** (a Code node, no AI) checks the sender id against
   `TELEGRAM_ALLOWED_IDS` (**fail closed** — empty id or empty allowlist denies),
   parses the command, validates it against the whitelist, and plans the action.
   It **mirrors** [`scripts/lib/bot-lib.sh`](../../scripts/lib/bot-lib.sh), the
   canonical logic covered by `tests/bot/`.
3. **Execute on host?** branches: executable commands go to the host bridge over
   **SSH**; everything else (denial / `/help` / unknown / validation error) gets
   a direct reply.
4. **Run bot-exec.sh on host** runs the validated `<action> <arg>` through the
   bridge, which **re-validates**, logs, and maps it to the existing tools.

### Commands (whitelist only)

| Command | Kind | Maps to |
|---|---|---|
| `/status` | read-only | `scripts/pi status` |
| `/health` | read-only | `scripts/pi health` |
| `/check` | read-only | `scripts/pi check` (preflight + mem-budget) |
| `/projects` | read-only | list generated projects + state |
| `/up <profile>` | state-changing | `scripts/pi up --profile <p>` (core·dev·auth·automation) |
| `/down <profile>` | state-changing | `scripts/pi down --profile <p>` |
| `/project_up <name>` | state-changing | `scripts/project.sh up <name>` |
| `/project_down <name>` | state-changing | `scripts/project.sh down <name>` |
| `/help` | — | answered in-workflow |

Anything else is refused. State-changing actions are logged by the bridge.

### Security model (read this)

- **Allowlist, fail closed.** Only Telegram ids in `TELEGRAM_ALLOWED_IDS` are
  served; an unknown sender gets a polite denial (delete the *Reply: message*
  link from the false branch to go fully silent). An **empty** allowlist
  authorizes **no one**.
- **Whitelist only.** Unknown commands are refused with `/help`.
- **n8n never runs arbitrary host commands.** It reaches the host only through
  `bot-exec.sh` over SSH with a **dedicated key**; the bridge validates every
  action and argument and never evals input — it is the real boundary.
- **No secrets in git.** Bot token → n8n **credential**; allowlist → `.env`.
  This JSON is committed; keep secrets out of it.

### One-time manual setup (deferred — do it on the Pi)

This needs an external account, so it is a **deferred operator step**:

1. **BotFather** → `/newbot` → copy the **token**.
2. Get **your** numeric Telegram user id (message `@userinfobot`).
3. In `.env` set `TELEGRAM_ALLOWED_IDS=<your id>` (comma-separate for several) and
   optionally `TELEGRAM_BOT_TOKEN`; restart n8n (`./scripts/automation.sh down &&
   up`) so `$env.TELEGRAM_ALLOWED_IDS` is visible to the workflow.
4. **Import** this file (editor → Import from File), create a **Telegram API**
   credential and select it on the trigger + both reply nodes.
5. Wire the **SSH** node to a dedicated key (recommended: pin it to a forced
   command — see the node's sticky note and `docs/README.md`), then **Save** and
   toggle **Active**.

Full walkthrough, the SSH forced-command hardening, and the bridge's action map:
[`docs/README.md`](../../docs/README.md) → *Telegram management bot*.
