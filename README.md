# pi-system

A self-hosted freelance platform toolkit for a **Raspberry Pi 5** (ARM64, SSD over PCIe): reverse proxy, auth, monitoring, backups, analytics, a Next.js control panel — plus a **scaffolding factory** that generates client projects (.NET APIs, Next.js apps, full-stack presets) from templates with one script.

## Highlights

- **43 operational shell scripts** (`scripts/`) — provisioning, backup + restore-verification, memory budgeting, health doctor
- **Composable services** (`services/`) — Caddy proxy, control panel (Next.js 15), SEO & prospects engines (pure Node ESM), analytics
- **Project templates** (`templates/`) — .NET API, Next.js, and full-stack bases with optional modules (local payments, bookings) merged in by `scripts/new-project.sh`
- **n8n automation** (`automation/`) — workflow exports including a Telegram management bot
- **Test harnesses** (`tests/`) — preflight checks, bot tests, control-api unit tests (Node test runner + shell)

## Getting started

Start with the ordered, copy-paste **[first-run runbook](docs/RUNBOOK.md)** — from a bare Pi to a verified, running platform.

Component reference: **[docs/README.md](docs/README.md)**. Unsure where you are? `./scripts/pi doctor` prints the next command.

## Configuration

Copy `.env.example` and fill in values — every secret is environment-injected; nothing sensitive is committed. `secrets/` and `data/` are gitignored volumes.

## License

MIT
