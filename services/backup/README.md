# services/backup — encrypted backups with tested restore

A platform-level backup system whose defining feature is **tested restore**: a
backup that is never restore-tested is a false safety net, so an automated
restore **drill** runs on a schedule into **disposable throwaway containers**
and fails loudly if a backup cannot be brought back.

Everything here is **encrypted at rest** (no plaintext dumps), **ARM64** and
**version-pinned**, connects to databases **by service name on the internal
network** using credentials from the root `.env`, opens **no host ports**, and
never disturbs the running services.

## What's here

| File | Purpose |
|------|---------|
| `Dockerfile` | Builds the ARM64 *toolbox* image: pinned `pg_dump`/`pg_dumpall` (from `postgres:16.6`), the official MySQL client (`mysqldump`, `caching_sha2_password`-capable), MongoDB Database Tools (`mongodump`/`mongorestore`, pinned `100.17.0`), `redis-cli`, and `age` (pinned `v1.3.1`) for encryption. |
| `backup.compose.yml` | Defines the one-shot, profile-gated `backup` job: `internal`-only, no host ports, mounts the backups dir, the age key (read-only), and the project root (read-only, for config backup). |
| `do-backup.sh` | Runs **inside** the container: detects which engines are up, dumps each with its proper tool, streams `dump → gzip → age` (never plaintext), writes a manifest, applies retention, updates a status file, and optionally pushes an Uptime Kuma heartbeat. |

The operator-facing entrypoints live in `scripts/`:

| Script | Role |
|--------|------|
| `scripts/backup.sh` | Front door: `init-key`, `now`, `list`, `verify`, `status`. |
| `scripts/backup-verify.sh` | **Tested-restore drill** into disposable containers (never touches live data). |
| `scripts/restore.sh` | **Real**, operator-confirmed restore into live databases (guarded; never auto-runs). |
| `scripts/backup-install-cron.sh` | Installs the daily backup + weekly drill schedule (host cron). |

## Quick start

```bash
# 1. One-time: generate the encryption key (KEEP A COPY OFFLINE).
./scripts/backup.sh init-key

# 2. Back up now (only the databases that are running are touched).
./scripts/backup.sh now

# 3. Prove it can be restored — into throwaway containers, not live data.
./scripts/backup-verify.sh

# 4. Schedule daily backups + the weekly drill.
./scripts/backup-install-cron.sh
```

## What gets backed up

* PostgreSQL (`postgres`), the isolated Keycloak DB (`keycloak-db`), MySQL
  (`mysql`), MongoDB (`mongo`), Redis (`redis`) — **only those currently up**.
* Any extra project databases listed in `BACKUP_EXTRA_TARGETS` (e.g.
  content-admin's dedicated `<project>-cms-db`).
* Critical config (compose files, Caddyfile, `.env`, ...). `.env` is included
  but, like everything else, **only ever encrypted** — `data/` and `secrets/`
  are excluded (the age key must not live inside its own backup).

## Encryption & key safety

Artifacts are encrypted with [`age`](https://github.com/FiloSottile/age) to the
public key derived from a git-ignored **age identity** (default
`./secrets/backup/age-identity.key`), or to explicit `BACKUP_AGE_RECIPIENTS`.
The identity is required to **restore** (and for the weekly drill), so:

> **Keep a copy of `secrets/backup/age-identity.key` somewhere safe and
> offline.** It is the only thing that can decrypt your backups; lose it and the
> backups are unrecoverable.

If neither a key nor recipients are configured, the backup job **aborts** rather
than writing any plaintext.

See **docs/README.md → "Backup & restore"** for the full model, retention,
scheduling, the guarded real-restore procedure, and the optional offsite step.
