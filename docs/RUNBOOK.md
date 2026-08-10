# pi-system — First-run RUNBOOK

**The one ordered, copy-paste guide from a bare Raspberry Pi 5 to a verified,
running platform.** Start here. Every step gives you the **exact command(s)**,
what a **successful result looks like**, and a short **"if it fails"** pointer
into the deeper docs — which this runbook *sequences and links* rather than
repeats. When in doubt about what to run next, ask the platform itself:

```bash
./scripts/pi doctor      # reads .env + secrets + live status, prints the next command
```

> **Read this top to bottom the first time.** The order is the safety contract:
> secrets before bring-up, core before optional, the firewall enabled only after
> you have confirmed the SSH rule, and the encryption keys stored offline before
> anything depends on them.

---

## Legend — which kind of step is this?

Each step is tagged so you know whether you do it once, per project, or later:

| Tag | Meaning |
| --- | ------- |
| 🟢 **one-time** | Run once when first standing the Pi up. |
| 🔁 **per-project** | Repeated each time you scaffold/expose a new client project. |
| 🌐 **deferred — external credentials** | Needs an account/console at an external provider (Meta, Moyasar, Keycloak realm, Cloudflare). Safe to defer to the guided manual session; the platform builds and runs on mocks/local TLS until then. |
| ⏭️ **optional** | Only when you need that capability. |

The data-safe rule holds throughout: nothing here deletes a named volume, and
`./scripts/pi down` always keeps your data.

---

## The whole sequence at a glance

```
A  Hardware / OS prep ............. 🟢   Pi 5 + SSD + Docker            → docker run hello-world
B  Get the code .................. 🟢   clone onto the Pi
C  Secrets (keys OFFLINE!) ....... 🟢   generate → fill → check-secrets
D  Preflight + memory budget ..... 🟢   pi check --profile core        → VERDICT: READY
E  First bring-up (core) ......... 🟢   pi up --profile core           → VERDICT: LIVE
F  Log rotation .................. 🟢   docker daemon caps + cron-log logrotate
G  Firewall (SSH-lockout aware) .. 🟢   harden-firewall.sh → ufw enable
H  Public access ................. 🌐⏭️  Cloudflare Tunnel + TLS
I  Optional stages ............... ⏭️   auth / automation / databases
J  Backups + restore drill ....... 🟢   init-key → cron → verify
K  Ongoing health ................ 🟢   health-monitor cron
L  First real project ............ 🔁   new-project.sh (portfolio)
M  Provider go-lives ............. 🌐   WhatsApp + Moyasar mock → live
```

After step **E** you have a running platform; **F–K** harden and operate it;
**L–M** put real work on it. The **[Deferred manual steps](#deferred-manual-steps-checklist)**
checklist and the **[Troubleshooting appendix](#troubleshooting-appendix)** are at
the end.

---

## A. Hardware & OS preparation 🟢

**Goal:** a Raspberry Pi 5 booting Raspberry Pi OS Lite (64-bit) **from an SSD
over PCIe/NVMe** (not an SD card — see the SD-vs-SSD risk in [Troubleshooting](#troubleshooting-appendix)),
with Docker Engine + Compose v2 installed.

1. **Flash Raspberry Pi OS Lite (64-bit)** to the NVMe SSD with Raspberry Pi
   Imager (set hostname, enable SSH, create your user in the Imager's advanced
   options). Fit the SSD on a PCIe HAT, and set the Pi to boot from NVMe
   (`raspi-config` → *Advanced* → *Boot Order* → *NVMe/USB*, or the bootloader
   config). Booting from SSD is the platform's assumption: backups, Docker layers
   and logs would wear an SD card out.
2. **Install Docker + the Compose v2 plugin** (from the project
   [Prerequisites](README.md#prerequisites)):
   ```bash
   curl -fsSL https://get.docker.com | sh
   sudo apt-get install -y docker-compose-plugin
   sudo usermod -aG docker "$USER"      # then log out and back in
   ```
3. **Verify architecture and Docker:**
   ```bash
   uname -m                 # expect: aarch64
   dpkg --print-architecture # expect: arm64
   docker run --rm hello-world
   docker compose version
   ```

**✓ Success looks like:** `uname -m` prints `aarch64`; `docker run --rm
hello-world` ends with *"Hello from Docker!"*; `docker compose version` prints a
**v2.x** version with **no `sudo`**.

**✗ If it fails:**
- `permission denied … /var/run/docker.sock` → the group change needs a fresh
  login: log out/in (or `newgrp docker`) and retry.
- `hello-world` pulls but won't run, or arch is not `aarch64` → you flashed a
  32-bit OS; re-flash the **64-bit** image.
- Compose says *"is not a docker command"* → install `docker-compose-plugin`
  (above). See [Prerequisites](README.md#prerequisites).

---

## B. Get the code onto the Pi 🟢

```bash
# from your home directory on the Pi
git clone <your-repo-url> pi-system     # or copy the project across with scp/rsync
cd pi-system
./scripts/pi help                       # the unified operator entrypoint
```

Everything below is run **from the project root** (`pi-system/`). `scripts/pi`
resolves paths relative to the root, so it works from anywhere inside, but the
examples assume you are at the top.

**✓ Success looks like:** `./scripts/pi help` prints the unified-control usage
(commands `check / up / status / health / down / doctor`). The directory layout
is described in [Project structure](README.md#project-structure).

**✗ If it fails:** `scripts/pi: No such file` → you are not in the project root,
or the clone is incomplete. `Permission denied` running a script → `chmod +x
scripts/*.sh scripts/pi` (the repo ships them executable; some transfers drop the
bit).

---

## C. Secrets — generate, fill, and store the keys OFFLINE 🟢

> ⚠ **This is the most important step to get right.** Two values are
> **unrecoverable if lost** and must be copied **offline** (a password manager,
> an encrypted USB key kept off the Pi):
> the **backup encryption key** (`secrets/backup/age-identity.key`) and
> **`N8N_ENCRYPTION_KEY`**. Lose the backup key and every encrypted backup is
> garbage; lose the n8n key and every stored n8n credential is unreadable. The
> Pi's SSD is **not** an offline copy.

All credentials live only in the git-ignored `.env`. Neither script below ever
prints a secret value.

```bash
# 1. Bootstrap: verify Docker, create data/ + secrets/, seed a blank .env  (idempotent)
./scripts/setup.sh

# 2. Fill every SECRET field in .env with a strong random value.
#    Use --force because setup.sh just created the .env (it backs the old one up first;
#    its non-secret fields were blank anyway). If you skipped setup.sh, drop --force.
./scripts/generate-secrets.sh --force

# 3. Fill the NON-secret values by hand (left blank on purpose):
nano .env
#    e.g. BASE_DOMAIN, ACME_EMAIL, the *_USER / *_DB names, KC_HOSTNAME,
#    the network names — see the comments in .env for each.

# 4. Create the two keys generate-secrets.sh does NOT fill — and copy them OFFLINE:
./scripts/backup.sh init-key                 # writes secrets/backup/age-identity.key (mode 600)
openssl rand -hex 32                          # paste the output into N8N_ENCRYPTION_KEY= in .env

# 5. Audit: must pass (exit 0) before you bring anything up.
./scripts/check-secrets.sh
```

`generate-secrets.sh` fills the database / admin-UI / Keycloak passwords; it does
**not** touch `N8N_ENCRYPTION_KEY` or the backup key — those are step 4. See
[Secrets — generate strong values, then audit](README.md#security-hardening).

**✓ Success looks like:** `./scripts/check-secrets.sh` prints only `✓` lines (or
`!` warnings for services you are not using yet) and **exits 0** — no `✗`, no
critical. A critical is a flat fail: empty `REDIS_PASSWORD`, an unset
`N8N_ENCRYPTION_KEY`, a missing backup key, or any too-short/known-weak value.

**✗ If it fails:**
- `✗ REDIS_PASSWORD is empty` / a too-short value → re-run
  `generate-secrets.sh --force` (then re-fill non-secrets) or set the value by
  hand, and re-audit.
- `✗ backup encryption key not configured` → you skipped `backup.sh init-key`
  (step 4).
- `✗ N8N_ENCRYPTION_KEY is empty` → paste the `openssl rand -hex 32` output into
  `.env` (step 4).

---

## D. Preflight & memory budget — is the host ready? 🟢

`pi check` runs the two **read-only** gates (it starts nothing): host/OS readiness
([preflight](README.md#preflight-check)) and whether the chosen profile fits in
RAM ([resource safety](README.md#resource-safety)).

```bash
./scripts/pi check --profile core
# Also check any heavier profile you intend to run before you run it, e.g.:
./scripts/pi check --profile auth
```

**Interpreting the result** — each check is **PASS / WARN / FAIL**:

| Result | Meaning | What to do |
| ------ | ------- | ---------- |
| **PASS** | Ready. | Proceed. |
| **WARN** | Worth knowing, not blocking — e.g. `/` looks like an **SD card**, or the registry could not be reached so image tags were checked **offline**. | Read it; on a real first run, address the SD-card warning (use an SSD). |
| **FAIL** | A hard problem — Docker down, a missing required `.env` var, a memory budget that overcommits RAM, a compose parse/port collision. | Fix it; `pi up` will refuse to start until you do. |

**✓ Success looks like:** `VERDICT: READY — the host passed every read-only
gate.` (`pi check` exit 0).

**✗ If it fails:** the verdict is `NOT READY` and names the failing gate.
- Memory budget FAIL → the profile sums past your RAM; run a lighter profile, or
  see [8 GB vs 16 GB](README.md#resource-safety) and bring heavy stacks (auth,
  automation) up only when needed.
- A required-variable or compose FAIL → fix `.env` / the collision it names; see
  [Preflight check](README.md#preflight-check).

---

## E. First bring-up — the core stack 🟢

The **core** profile is the always-on set: Caddy (edge), the management trio
(Portainer, Uptime Kuma, Watchtower) and the Homepage dashboard (~1.0 GiB).
`pi up` re-runs the gates itself, then does the **staged, verified** bring-up,
**halting on the first failure**.

```bash
./scripts/pi up --profile core      # add --dry-run first to just print the plan
./scripts/pi status                 # whole-system snapshot + verdict
```

Then open the dashboard **locally**: browse to `https://<BASE_DOMAIN>/`
(e.g. `https://localhost`). Locally Caddy serves its **internal-CA** certificate,
so your browser will warn — accept it for local testing (a public domain gets a
real Let's Encrypt cert, step H). See [Dashboard (Homepage)](README.md#dashboard-homepage)
and [Reverse proxy](README.md#reverse-proxy).

**✓ Success looks like:** `VERDICT: LIVE — every step passed; the selected stack
is up.` and `pi status` shows the core services **healthy/running**, the
`pi_internal` + `pi_proxy` networks **present**, and `VERDICT: UP`. The Homepage
loads with cards for each service.

**✗ If it fails (isolating a failed stage):** `pi up` prints `VERDICT: HALTED —
"<stage>" failed; nothing after it ran.` Only that stage and earlier ran. Inspect
it and re-run (the bring-up is idempotent — healthy stages are left untouched):
```bash
docker logs <container>            # or use Portainer once it is up
./scripts/pi up --profile core     # safe to re-run after a fix
```
See [how a failure is isolated and diagnosed](README.md#staged-bring-up).

---

## F. Apply log rotation (bound container logs) 🟢

Docker's default log driver has **no size cap**, so over weeks a chatty container
can fill the SSD. Apply the daemon-wide cap from
[`infrastructure/docker-daemon.json.example`](../infrastructure/docker-daemon.json.example):

```bash
sudo cp infrastructure/docker-daemon.json.example /etc/docker/daemon.json
#   if /etc/docker/daemon.json already exists, MERGE the keys by hand instead of overwriting
sudo systemctl restart docker
```

> **Ordering caveat.** This only takes effect for a container when it is
> (re)created, and `systemctl restart docker` briefly stops running containers
> (data-safe — volumes persist). Two clean options:
> - **Best:** apply it right after installing Docker (step A), *before* the first
>   bring-up, so every container is created bounded from the start.
> - **If you applied it after core was already up:** re-run
>   `./scripts/pi up --profile core` so the containers are recreated with the new
>   log config.

**✓ Success looks like:** `docker info --format '{{.LoggingDriver}}'` prints
`json-file`, and `/etc/docker/daemon.json` contains the `max-size` / `max-file`
caps. New containers inherit them.

**✗ If it fails:** Docker won't restart after the copy → the file is invalid
JSON (a bad hand-merge). Fix the JSON (`sudo cat /etc/docker/daemon.json`) and
restart. See [Log hygiene](README.md#resource-monitoring).

**Also bound the host-side cron logs.** The daemon cap above bounds every *container*
log. The scheduled helpers, however, append their output to plain files on the host —
`data/seo/cron.log`, `data/prospects/cron.log`, `data/backups/status/cron.log` (the
`health-monitor` log is already self-bounded). These grow slowly but never shrink on
their own. Add a `logrotate` rule (run from the project root so `$(pwd)` resolves to it):

```bash
sudo tee /etc/logrotate.d/pi-system >/dev/null <<EOF
$(pwd)/data/*/cron.log $(pwd)/data/*/status/cron.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
    copytruncate
}
EOF
```

`copytruncate` lets the cron jobs keep appending to the same path across rotations (no
restart needed). Verify with `sudo logrotate --debug /etc/logrotate.d/pi-system`.

---

## G. Firewall — staged for you, enabled by you ⚠️ 🟢

[`harden-firewall.sh`](../scripts/harden-firewall.sh) **stages** a
default-deny-incoming UFW policy that allows only SSH (22) and Caddy (80/443
tcp + 443 udp). **It does not turn the firewall on** — you do that deliberately,
after confirming the SSH rule, so a default-deny policy is never switched on over
SSH without a human in the loop.

```bash
sudo ./scripts/harden-firewall.sh                  # default SSH port 22
# sudo ./scripts/harden-firewall.sh --ssh-port 2222  # if you run SSH on a custom port
```

> ⚠ **SSH-LOCKOUT WARNING — read before enabling.** Turning on a default-deny
> firewall over SSH can cut your session permanently if the SSH port is not
> allowed. Before and during enabling:
> 1. Confirm an **SSH rule for your port** appears in the printed preview.
> 2. Keep your **current SSH session open** as a safety net.
> 3. Enable, then open a **second, new** SSH session to confirm you still get in
>    **before** closing the first:
>    ```bash
>    sudo ufw enable
>    sudo ufw status verbose      # verify: default deny incoming; 22, 80, 443 allowed
>    ```
>
> **If you get locked out** it cannot be fixed over SSH — you need **local/console
> access** (monitor + keyboard, or serial). Then:
> ```bash
> sudo ufw disable                    # turn it back off, OR
> sudo ufw allow <your-ssh-port>/tcp  # add the missing SSH rule
> ```

**✓ Success looks like:** `sudo ufw status verbose` shows **Default: deny
(incoming)** and allow rules for 22 (your SSH port), 80, 443; a **second** SSH
session connects.

**✗ If it fails / lockout:** use the console-recovery commands above. To start
the rules over: `sudo ufw reset`. Note the documented [Docker-can-bypass-UFW
caveat](README.md#security-hardening) — this platform is already safe because
only Caddy publishes host ports. Full detail: the **Firewall (UFW)** and
**Pre-exposure security checklist** parts of [Security hardening](README.md#security-hardening).

---

## H. Public access — Cloudflare Tunnel + TLS 🌐 ⏭️

Make a web-facing project reachable from the internet over HTTPS **without
opening any inbound port** — a `cloudflared` tunnel dials *outbound* to Cloudflare
and forwards to the existing Caddy, which still issues a **real public Let's
Encrypt certificate** via its own ACME. This is **optional** and involves a
**Cloudflare account** (deferred — external).

**One-time setup** (install + configure `cloudflared`, link the tunnel to Caddy,
add the DNS record, automatic Let's Encrypt) is the full walkthrough in
[**`docs/cloudflare-tunnel.md`**](cloudflare-tunnel.md). Set `BASE_DOMAIN` and
`ACME_EMAIL` in `.env` so Caddy issues public certs (it enforces HTTP→HTTPS).

**Per-project, after the one-time setup**, the helper automates copy + DNS + Caddy
+ reload from your dev machine over SSH:
```bash
./scripts/deploy-to-tunnel.sh --name shop --subdomain shop --email you@example.com
```

**✓ Success looks like:** `https://<subdomain>.<BASE_DOMAIN>` loads from outside
your network with a **publicly trusted** certificate (no browser warning).

**✗ If it fails:** see the troubleshooting in [`cloudflare-tunnel.md`](cloudflare-tunnel.md)
and the [TLS-via-tunnel](#troubleshooting-appendix) note below. Always run
`./scripts/check-secrets.sh` and the **Pre-exposure security checklist** in
[Security hardening](README.md#security-hardening) **before** pointing a domain at
the Pi.

---

## I. Optional stages — auth, automation, databases ⏭️

Bring these up only when you need them, and take the heavy ones (auth, automation)
**down when idle** — each is ~2 GiB. Always `pi check` the profile first.

**Authentication (Keycloak)** ⏭️ + 🌐
```bash
./scripts/pi check --profile auth
./scripts/pi up --profile auth
```
First login & bootstrap (create a permanent admin, retire the bootstrap admin) is
in [Authentication (Keycloak)](README.md#authentication-keycloak). Creating a
**realm + a client per project** is the deferred external step in
[`auth-sso/SETUP.md`](../templates/modules/auth-sso/SETUP.md).

**Automation (n8n)** ⏭️
```bash
./scripts/pi up --profile automation
```
Then create the n8n **owner account** in the editor and **import** the bundled
workflow: editor → *Import from File* →
[`automation/workflows/platform-health-alert.json`](../automation/workflows/platform-health-alert.json)
→ *Save* → toggle **Active**. See [Automation (n8n)](README.md#automation-n8n).

**Databases / cache** ⏭️ (usually started for you by a project's next-steps output)
```bash
./scripts/db.sh <postgres|mysql|mongo|redis> up    # start a single engine on-demand
```
See [Databases](README.md#databases). Or use the **dev** profile
(`pi up --profile dev`) for core + Postgres + the package cache while iterating.

**✓ Success looks like:** `pi status` shows the new stage's services healthy and
no longer under "Currently off". **✗ If it fails:** the same halt/inspect/re-run
loop as step E.

---

## J. Backups + a tested restore drill 🟢

The backup system's defining feature is **tested restore**: a drill restores into
disposable throwaway containers and, after restoring, runs a **post-restore health
self-check** on each store (a trivial read — `SELECT 1` / `ping` / key count / file
presence) so it proves the data is actually *usable*, not merely unpacked. Every
artifact is **encrypted at rest**, and every run writes an **integrity manifest**
(per-member SHA-256 + byte size, the age-recipient fingerprint, a timestamp and a
schema version) that the dry-run plan and the drill both read.

```bash
# 1. The encryption key (once) — you already did this in step C; init-key is idempotent.
./scripts/backup.sh init-key          # KEEP A COPY OFFLINE (see step C warning)

# 2. Schedule: daily backup 02:30 + weekly restore-drill Sun 03:30 (host cron)
./scripts/backup-install-cron.sh      # --dry-run to preview the crontab block first

# 3. Run a restore DRILL now to prove the backups actually restore (never touches live data)
./scripts/backup-verify.sh            # or: ./scripts/backup.sh verify

# 3b. BEFORE you ever rely on a backup, PLAN the restore — a read-only, container-free
#     check that validates an archive against its manifest and prints SAFE / NOT-SAFE.
./scripts/backup.sh restore --dry-run data/backups/daily/<TS>   # changes nothing

# 4. (optional) offsite copy — built in via rclone (the encrypted artifacts go offsite)
#    Install rclone, create a remote, set the three BACKUP_OFFSITE_* keys in .env, then:
rclone --config ./secrets/backup/rclone.conf config   # create the remote once (e.g. "b2")
./scripts/backup.sh offsite                            # push now; 'backup.sh now' also auto-pushes
```

Only **running** databases are backed up (the DB layer is on-demand; a stopped
engine is skipped, not an error). **Offsite copy** is built in: set
`BACKUP_OFFSITE_TYPE=rclone`, `BACKUP_OFFSITE_REMOTE` (e.g. `b2:my-pi-backups`) and
`BACKUP_OFFSITE_CONFIG` in `.env`, and every `backup.sh now` then **pushes the
already-encrypted `data/backups/` offsite** with `rclone copy` (never deletes at the
destination; the remote never sees plaintext). Outcome is recorded in
`data/backups/status/last-offsite.json` and shown by `backup.sh status`.

**Restore dry-run (plan mode).** `./scripts/backup.sh restore --dry-run <archive>`
validates a backup run against its manifest — every artifact present, byte sizes +
checksums match, the age key is available, the schema is known — and prints a clear
plan ending in a single **`OVERALL: SAFE-TO-RESTORE`** / **`NOT-SAFE`** line. It
touches **no** live data and **no** container, so you can trust a backup *before* you
need it. The real, destructive restore stays the separate, guarded
[`./scripts/restore.sh`](../scripts/restore.sh).

**Failure alerts.** If a *scheduled* backup or the offsite push fails, `backup.sh now`
surfaces it through the same notifier seam as the rest of the platform
(`BACKUP_NOTIFY_CMD`, default [`notify-telegram.sh`](../scripts/notify-telegram.sh),
gated + best-effort) — so a silent backup failure can't go unnoticed. Set
`TELEGRAM_BOT_TOKEN` + a chat id (RUNBOOK step 6) to receive them; leave it and the
failure is still recorded on disk and (if set) pushed to Uptime Kuma.

**✓ Success looks like:** `./scripts/backup.sh status` shows a recent backup and
the last drill as **PASS**; `backup-verify.sh` reports **PASS per store** (restored
**and** health-checked) and exits 0; `restore --dry-run` prints **SAFE-TO-RESTORE**.

**✗ If it fails:**
- `Backup encryption is not configured` → run `backup.sh init-key` (step C/J-1).
- A drill **FAIL** for a store → that backup is not restorable/usable; investigate
  before trusting it. See [Tested restore](README.md#backup--restore).
- `restore --dry-run` says **NOT-SAFE** → resolve the listed PROBLEM(s) first: a
  missing age key (restore your offline copy), a checksum/size mismatch (corrupt
  archive — use an earlier run), or a missing artifact.

---

## K. Ongoing health monitoring 🟢

[`health-monitor.sh`](../scripts/health-monitor.sh) is a read-only probe of the
three slow-burn Pi risks — **thermal, disk, memory** — that Uptime Kuma can't
see. Schedule it (same host-cron approach as backups):

```bash
./scripts/health-monitor-install-cron.sh      # every 15 min -> ./data/health
./scripts/pi health                            # run the probe once, now
```

**Where alerts surface** (PASS/SKIP are silent):
1. **Default, zero-config:** `data/health/last-alert.txt` + `data/health/last-health.json`.
2. **Uptime Kuma push** (optional): set `HEALTH_UPTIME_KUMA_PUSH_URL` → it lands
   on the existing Uptime Kuma card on the **Homepage**, next to service health.
3. **Telegram** (recommended for clients): set
   `HEALTH_NOTIFY_CMD=./scripts/notify-telegram.sh`. It reuses your bot token +
   `TELEGRAM_ALERT_CHAT_ID` (or the first `TELEGRAM_ALLOWED_IDS`) to push WARN/FAIL to
   the same chat you control the platform from. Verify:
   `echo test | ./scripts/notify-telegram.sh TEST` should arrive in Telegram.
   (The n8n `platform-health-alert` workflow covers *service-down* alerts the same way —
   enable its "Notify Telegram" node.) Or point `HEALTH_NOTIFY_CMD` at any script of your own.

**Reading `pi status`:** it folds host health into one line and an overall
verdict — **UP**, **DOWN** (nothing running — not an error), or **DEGRADED**
(something running is broken, exit 1). See [Resource monitoring](README.md#resource-monitoring).

**✓ Success looks like:** `./scripts/pi health` prints `VERDICT: PASS`; `crontab
-l` shows the health job. **✗ If it fails:** a FAIL names the resource over
threshold (and, on disk pressure, the biggest consumer to prune) — see
[Resource monitoring](README.md#resource-monitoring).

---

## L. Generate your first real project 🔁

A good first project is your **portfolio / company site**. The generator
scaffolds it into `services/`, wires it to a database by service name, fronts it
with Caddy, and writes a `PROJECT.md` listing any deferred steps.

```bash
# Scaffold (the company-site preset; served at https://portfolio.<BASE_DOMAIN>)
./scripts/new-project.sh --name portfolio --preset company-site --subdomain portfolio

# Bring it up (the generator prints the exact next steps for THIS project):
./scripts/db.sh <engine> up        # only if the preset uses a DB (skip if it says --db none)
./scripts/start-proxy.sh           # ensure Caddy is up / re-read the Caddyfile
./scripts/project.sh up portfolio  # build + start the project

# Expose it: locally browse https://portfolio.<BASE_DOMAIN>, or publish via step H:
./scripts/deploy-to-tunnel.sh --name portfolio --subdomain portfolio --email you@example.com
```

See [Templates & project generator](README.md#templates--project-generator).
Generated projects appear in `pi status` under **Generated projects**.

**✓ Success looks like:** `new-project.sh` finishes and prints next steps;
`./scripts/project.sh status portfolio` shows the container up; the page loads at
`https://portfolio.<BASE_DOMAIN>`.

**✗ If it fails:** a build/start error → `./scripts/project.sh logs portfolio`.
The new subdomain 404s in Caddy → reload it:
`docker exec pi-system_caddy caddy reload --config /etc/caddy/Caddyfile` (or
re-run `./scripts/start-proxy.sh`). See [Run a generated project](README.md#templates--project-generator).

---

## M. External provider go-lives — mock → live 🌐

Modules ship on a **mock/sandbox provider** so projects build and run with no
external account. Flipping to live is just env vars + a restart — **no code
changes**. Do these in the guided manual session once you have the accounts.

**WhatsApp Cloud API** — full steps in
[`whatsapp-integration/SETUP.md`](../templates/modules/whatsapp-integration/SETUP.md):
```dotenv
WHATSAPP_PROVIDER=cloud_api
WHATSAPP_PHONE_NUMBER_ID=<from Meta>
WHATSAPP_ACCESS_TOKEN=<permanent token from Meta>
# only if you registered the inbound webhook:
WHATSAPP_VERIFY_TOKEN=<the token you chose>
WHATSAPP_APP_SECRET=<your Meta app secret>
```

**Moyasar payments** (mada / Apple Pay / cards) — full steps in
[`local-payments/SETUP.md`](../templates/modules/local-payments/SETUP.md):
```dotenv
PAYMENTS_PROVIDER=moyasar
PAYMENTS_API_KEY=sk_live_xxxxxxxxxxxxxxxx
PAYMENTS_WEBHOOK_SECRET=<the webhook secret token you set in Moyasar>
PAYMENTS_CURRENCY=SAR
```

Then restart the affected project: `./scripts/project.sh up <name>`.

**✓ Success looks like:** a live `curl` to the project's `/api/whatsapp/send` or
`/api/payments` endpoint returns the live provider's response (the exact test
calls are in each SETUP.md). To revert, set the provider back to `mock` and
restart.

**✗ If it fails:** webhooks need the project reachable over **public HTTPS**
(step H) — Meta/Moyasar cannot POST to a non-public host. See each SETUP.md's
notes.

---

## Deferred manual steps checklist

Every external-credential / console task in one place — none blocks the platform
from running; each is for the **guided manual session**:

- [ ] **Offline copies** of `secrets/backup/age-identity.key` **and**
      `N8N_ENCRYPTION_KEY` are stored off the Pi. → **step C** above
- [ ] **Keycloak realm + a client per project** (auth-sso). →
      [`auth-sso/SETUP.md`](../templates/modules/auth-sso/SETUP.md)
- [ ] **n8n owner account** created + **health workflow imported & activated**. →
      [Automation (n8n)](README.md#automation-n8n)
- [ ] **Cloudflare Tunnel** one-time setup for public access + DNS. →
      [`cloudflare-tunnel.md`](cloudflare-tunnel.md)
- [ ] **WhatsApp Cloud API** go-live (Meta app, phone-number id, permanent
      token, webhook). → [`whatsapp-integration/SETUP.md`](../templates/modules/whatsapp-integration/SETUP.md)
- [ ] **Moyasar** go-live (merchant account, secret key, webhook + secret
      token). → [`local-payments/SETUP.md`](../templates/modules/local-payments/SETUP.md)
- [ ] **Offsite backups** configured — set `BACKUP_OFFSITE_*` and create the rclone
      remote; the built-in push runs with every `backup.sh now`. → **step J-4** above
- [ ] **SSH hardening** (key-only auth, root login disabled) — outside this
      repo's scope, strongly recommended. → [Security hardening](README.md#security-hardening)

---

## Troubleshooting appendix

The most likely first-run issues, indexed to the tool/doc that addresses each:

| Symptom | Most likely cause | Where to go |
| ------- | ----------------- | ----------- |
| **RAM pressure** — OOM kills, swap thrashing, a memory-budget FAIL | Profile sums past your Pi's RAM, or a heavy stack (Keycloak/n8n) left running | `pi check` ([memory budget](README.md#resource-safety)); take heavy profiles `down` when idle; watch with `pi health` / [Resource monitoring](README.md#resource-monitoring) |
| **A stage failed** — `VERDICT: HALTED` during `pi up` | One service didn't come up healthy; later stages were skipped | Re-run `pi up` (idempotent); `docker logs <ctr>` / Portainer; [failure isolation](README.md#staged-bring-up) |
| **Image tag / arch error** — pull fails, or "no matching manifest for linux/arm64" | A tag missing from the registry, or a non-ARM64 image | `pi check` flags this (offline ⇒ WARN, not a false FAIL); [Preflight](README.md#preflight-check); never use `latest`, pin ARM64 tags ([Conventions](README.md#conventions--hard-rules)) |
| **TLS errors over the tunnel** — cert warnings, JWKS/metadata fetch fails | Local internal-CA certs aren't publicly trusted; public certs need `BASE_DOMAIN`/`ACME_EMAIL` | [`cloudflare-tunnel.md`](cloudflare-tunnel.md); for local auth testing only, the internal-CA notes in [`auth-sso/SETUP.md`](../templates/modules/auth-sso/SETUP.md) |
| **SSH lockout** after enabling UFW | The SSH rule wasn't allowed before `ufw enable` | **Console access** → `sudo ufw disable` or `sudo ufw allow <port>/tcp`; the **Firewall (UFW)** part of [Security hardening](README.md#security-hardening) and **step G** above |
| **Running off an SD card** (not SSD) | OS flashed to / booting from microSD | `pi check` WARNs on SD/eMMC boot media; re-image to NVMe SSD (**step A** above); disk wear is watched by [Resource monitoring](README.md#resource-monitoring) |
| **`check-secrets` critical** | Empty Redis/n8n key, missing backup key, weak value | Re-run **step C** above; [Secrets](README.md#security-hardening) |
| **`pi status` says UNKNOWN** | Docker/Compose not reachable from where you ran it | Run it **on the Pi**; ensure the Docker daemon is up |

When unsure where you are in this sequence, run **`./scripts/pi doctor`** — it
reports `.env` / secrets / system state and prints the single next command.

---

## Going live with clients — production-readiness gate ✅

Before you host a **paying client's** site or data, run this gate end to end. Each item
is a hard PASS/FAIL with a one-line proof; do **not** onboard a client until all nine
read PASS. Run everything **on the Pi** (most checks need Docker + the real `.env`).
Item **1** is a one-command live smoke test that summarizes the rest; items **2–9** are
the detailed, item-by-item verification.

```bash
# 0. One command that tells you where you are, anytime:
./scripts/pi doctor
```

**1. Live smoke test — one command proves the running stack end to end.**
```bash
./scripts/smoke-test.sh                       # or: --url https://a-site-you-own.example
```
This is the LIVE counterpart to the offline `tests/` suites (which mock everything): it
checks the REAL system on the Pi and prints a PASS/FAIL table with a remediation hint
under any failure, ending in a single `OVERALL:` line. ✓ PASS (`OVERALL: PASS`): core
containers up; Caddy owns **only** host ports 80/443; internal services are unreachable
from the host; secrets are clean; the audited control bridge answers a read-only action;
the SEO/prospects engine returns a full audit object (all 5 category scores + a verdict)
**and** the SSRF guard refuses the cloud-metadata IP `169.254.169.254` (no fetch); and the
Telegram notifier is wired + gated (a dry-run sends nothing, never leaks the token). It is
idempotent and writes only to the platform's OWN data (a throwaway `data/seo/…/smoke-*`
audit), never to client data. On a box without Docker it SKIPs and exits 0. ✗ FAIL → fix
the hint under the failing row and re-run; the matching detailed item below has the depth.

**2. Secrets are strong (no critical findings).**
```bash
./scripts/check-secrets.sh        # must exit 0
```
✓ PASS: "No critical secret problems found." (every secret set, REDIS + N8N_ENCRYPTION_KEY
present, the age BACKUP key configured). Note `generate-secrets.sh` fills all 11 secret keys;
a regression test keeps the two lists in lock-step. ✗ FAIL → fix per **step C**, re-run.

**3. Firewall staged + the 80/443-only invariant holds.**
```bash
sudo ./scripts/harden-firewall.sh         # stages SSH + 80/443 (tcp+udp), default-deny in
grep -rn 'ports:' infrastructure services  # only Caddy publishes 80/443 — nothing else
sudo ufw enable                            # deliberate; keep this SSH session open, test a 2nd
```
✓ PASS: `ufw status` shows only your SSH port + 80/443; **no** container other than Caddy
publishes a host port. ✗ FAIL → never expose until only Caddy binds the host (**step G**).

**4. SSRF guard active on every untrusted fetch.**
The default audit engine (the one that fetches **prospect / client** URLs, incl. scheduled
runs) passes every URL — and **every redirect hop** — through the SSRF guard, refusing the
cloud-metadata IP, Docker service names and the LAN. Proof: `./tests/seo/run.sh` (the
"probeUrl wiring" checks). ⚠ The **opt-in** `lighthouse` engine fetches via Chromium and is
**not** behind the guard — run it **only against sites you own** (it is never used for
prospects). ✓ PASS: seo suite green + lighthouse used for owned sites only.

**5. Backups run, a restore drill succeeds, AND the latest archive plans SAFE.**
```bash
./scripts/backup.sh now            # encrypted backup of every running DB + config
./scripts/backup.sh verify         # TESTED restore into throwaway containers (never live);
                                   #   each store is restored AND health-checked (SELECT 1/ping/…)
./scripts/backup.sh restore --dry-run data/backups/daily/<TS>   # read-only plan: SAFE / NOT-SAFE
./scripts/backup.sh status         # recent backup + last drill = PASS, not stale
```
✓ PASS: drill reports **PASS per store** (restored *and* health-checked) and exits 0, and
`restore --dry-run` prints **`OVERALL: SAFE-TO-RESTORE`**. ✗ FAIL → a backup that won't
restore is no backup; investigate before trusting it (**step J**). A scheduled backup or
offsite failure also alerts via `BACKUP_NOTIFY_CMD` (set up your chat in step 7).

**6. Offsite encrypted copy is wired.**
```bash
# .env: BACKUP_OFFSITE_TYPE=rclone, BACKUP_OFFSITE_REMOTE=<remote:path>, BACKUP_OFFSITE_CONFIG=...
rclone --config ./secrets/backup/rclone.conf config   # create the remote once
./scripts/backup.sh offsite        # pushes the ALREADY-ENCRYPTED data/backups/ offsite
```
✓ PASS: "✓ Offsite copy complete" and `data/backups/status/last-offsite.json` shows
`"ok":true`; the daily `backup.sh now` keeps it current. The destination only ever holds
age-encrypted artifacts. ✗ FAIL → check the remote/credentials and re-run `backup.sh offsite`.

**7. Health alerts reach Telegram.**
```dotenv
# .env:
HEALTH_NOTIFY_CMD=./scripts/notify-telegram.sh
TELEGRAM_BOT_TOKEN=<from BotFather>
TELEGRAM_ALERT_CHAT_ID=<your chat id>   # or rely on the first TELEGRAM_ALLOWED_IDS
```
```bash
echo "go-live test" | ./scripts/notify-telegram.sh TEST   # must arrive in your Telegram
```
✓ PASS: the test message lands in your chat; a real WARN/FAIL from `pi health` then notifies
the same chat. (Also enable the n8n `platform-health-alert` "Notify Telegram" node for
service-down alerts.) ✗ FAIL → check the token/chat id; the sender never prints the token.

**8. The full prospect pipeline works on one real site you own, end to end.**
```bash
./scripts/prospects.sh add "My Own Business" --url https://your-own-site.example
./scripts/prospects.sh analyze my-own-business --notify --pdf   # audit→verdict→report→alert→follow-up
./scripts/prospects.sh show my-own-business                     # the analysis + report path are saved
```
✓ PASS: a report is written under `data/prospects/…`, the operator alert arrives (item 7),
and a follow-up date is set. Single-flight is enforced (an overlapping run skips cleanly).
Use a site **you own** for this dry run before touching real prospects. ✗ FAIL →
`./scripts/prospects.sh status` + the engine logs.

**8b. (Optional) Re-audit monitoring for existing clients.**
Turn the one-shot auditor into an ongoing signal: `./scripts/seo.sh reaudit <site>` re-audits a
site you already track and surfaces WHAT CHANGED vs the previous run. The report gains a
**"Changes since last audit"** section (per-category + tier moves, and the resolved/new/persisting
findings), and a concise operator heads-up is pushed through the **same gated notifier** (item 7)
**only on a meaningful change** — a new critical/high finding, a tier drop, or the site going
offline. It is **operator-only** (never the client), **single-flight** (shares the audit lock),
and **off by default**.
```bash
./scripts/seo.sh reaudit happy-teeth                 # diff vs the previous audit; alert only on a regression
# Schedule weekly (host cron) to monitor a hosted client, e.g.:
# 0 6 * * 1  cd <project> && ./scripts/seo.sh reaudit happy-teeth >> data/seo/cron.log 2>&1
```
✓ PASS: the report shows a "Changes since last audit" section; a regression pushes a heads-up while
an improvement / no-change is silent (the first run records a baseline and never alerts). ✗ FAIL →
check the site URL and `data/seo/cron.log`. _(For a prospect record, re-running
`./scripts/prospects.sh analyze <id> --notify` produces the same diff-driven regression alert.)_

**9. Whole-system verdict is healthy.**
```bash
./scripts/pi status        # overall UP (or DEGRADED=exit 1 if something running is broken)
./scripts/pi health        # VERDICT: PASS (thermal/disk/memory)
```
✓ PASS: `UP` + `PASS`. Schedule the recurring jobs if you haven't:
`backup-install-cron.sh`, `health-monitor-install-cron.sh`, `seo-install-cron.sh`.

> **Client data note.** Each generated project gets its own DB (by service name) and its
> own secrets; never share one client's DB/credentials with another. Keep the offline copies
> of `age-identity.key` + `N8N_ENCRYPTION_KEY` (step C) — they are unrecoverable if lost.

---

## You're ready

After **A–E** the platform is live; **F–K** harden and operate it; **L–M** put
real projects and live providers on it; the
**[Going live with clients](#going-live-with-clients--production-readiness-gate-)**
gate is the final PASS/FAIL checklist before you onboard a paying client. For the
day-to-day commands and the deep reference for every component, see
[`docs/README.md`](README.md). The
**[deferred checklist](#deferred-manual-steps-checklist)** above is your agenda
for the guided manual session.
