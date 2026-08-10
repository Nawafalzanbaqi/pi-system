# Telegram management bot — test harness

Unit tests for the deterministic logic behind the
[Telegram management bot](../../automation/workflows/telegram-management-bot.json):
the command parser, the **allowlist** authorization rule, the **whitelist** of
actions, argument validation, and the audited execution bridge
[`scripts/bot-exec.sh`](../../scripts/bot-exec.sh).

The bot has **no AI** — every command is deterministic — so all of its logic is
testable as pure functions plus the bridge run in **dry-run** mode. The canonical
logic lives in [`scripts/lib/bot-lib.sh`](../../scripts/lib/bot-lib.sh); the n8n
workflow's Code node **mirrors** the same tables. This harness sources that
library and runs the real `bot-exec.sh` against **fixtures** and **mocked seams**,
so everything is verified **without Docker, n8n or Telegram** — exactly how every
prior part of this platform was checked on the dev box.

## Run it

```bash
./tests/bot/run.sh
```

It prints a `✓ / ✗ / ~` line per assertion and **exits non-zero if any test
fails**. No Docker, no network, no bot token, and no service needs to be running.

## What it covers

Each case maps to a way the bot could go wrong:

| Area | Verified with |
| ---- | ------------- |
| **Command parser** | `bot_parse_command` — leading slash, `@botname` mention stripped, case-folding, first-two-token split, whitespace trim, empty input |
| **Whitelist** | `bot_known_command` / `bot_action_for` / `bot_valid_action` — every command known; `/help` is answered in-workflow (no bridge action); unknown verbs and hostile keys (`@`, `*`, `;`, empty) refused |
| **Classification** | `bot_is_readonly_action` vs `bot_is_state_action` and `bot_action_arg_rule` (none / profile / project) for all eight actions |
| **Argument validation** | `bot_valid_profile` (core·dev·auth·automation; `full-ish`/junk/injection rejected), `bot_valid_project_name` (shape), and `bot_known_project` against the **fixture** services dir (marker-based discovery; a platform dir is **not** a project) |
| **Allowlist auth (fail closed)** | `bot_authorized` — allowed id (single / CSV / space list) passes; unlisted id, **empty** allowlist, blank allowlist, empty sender, and substring all **denied** |
| **Help** | `bot_help_text` lists every command and leaks no token |
| **The bridge** | the **real** `scripts/bot-exec.sh` in `BOT_EXEC_DRYRUN=1`: each valid action maps to the right tool (`/status`→`pi status`, `/up`→`pi up --profile … -y`, `/project_up`→`project.sh up …`), `/up` defaults to `core`, read-only vs state-changing is classified, and unknown action / bad profile / wrong arity / unknown-or-malformed project are **refused** (exit 2) |
| **SSH forced-command path** | `--from-ssh` reads `$SSH_ORIGINAL_COMMAND`, tolerates a `cd <dir> &&` prefix, and **rejects injection** (`status; rm -rf /`, `status && reboot`, empty) — re-validating, never evaling |
| **Audit log** | every invocation (accepted **and** refused) is written to the log file |
| **Integrity** | `bot-lib.sh` / `bot-exec.sh` / `check-secrets.sh` parse (`bash -n`); the bridge's target scripts exist; the workflow JSON is valid and carries the trigger + auth + bridge nodes and ships **inactive** |
| **Secrets** | `check-secrets.sh` **warns** when `TELEGRAM_BOT_TOKEN` is set but `TELEGRAM_ALLOWED_IDS` is empty, and is quiet when the allowlist is set (guarded: skipped if a real `.env` is present) |

## Fixtures (`fixtures/`)

All committed fixtures are **secret-free**:

- `services/acme-portal/acme-portal.compose.yml` — a **generated project** (carries
  the `# pi-system-subdomain:` marker), so `bot_list_projects` discovers it.
- `services/proxy/proxy.compose.yml` — a **platform service** dir with the same
  file shape but **no** marker, so it must **not** be listed as a project (the
  bridge will refuse `/project_up proxy`).

## Adding a check

1. Put the pure decision in `scripts/lib/bot-lib.sh` and **mirror** it in the
   workflow's Code node (`telegram-management-bot.json`).
2. If it changes the bridge, route it through a **seam** in `scripts/bot-exec.sh`
   so dry-run can exercise it.
3. Add an assertion here and re-run `./run.sh`. The five sibling suites must stay
   green too.
