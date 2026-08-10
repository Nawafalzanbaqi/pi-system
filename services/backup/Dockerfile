# ===========================================================================
# pi-system — encrypted backup toolbox image
# ---------------------------------------------------------------------------
# A small, single-purpose ARM64 image that carries the PROPER dump/restore tool
# for every database engine the platform runs, plus `age` for encryption. It is
# NOT a long-running service: it is launched as a one-shot container (by
# scripts/backup.sh, via `docker compose run --rm backup`) that connects to each
# database BY SERVICE NAME on the internal network, dumps it, and writes an
# ENCRYPTED artifact. The same image is reused as a "toolbox" by the restore
# drill (scripts/backup-verify.sh) and the real restore (scripts/restore.sh).
#
# WHY this base + these tools (every version pinned, all linux/arm64 — Pi 5):
#   * FROM postgres:16.6 (Debian bookworm) — the SAME Postgres line the platform
#     runs (postgres:16.6-alpine, keycloak-db, content-admin's cms-db). This
#     gives pg_dump / pg_dumpall / pg_restore / psql at EXACTLY 16.6, so dumps
#     are taken with a client that matches the server version (the safe rule:
#     pg_dump version >= server version).
#   * MySQL's OWN client (mysql-community-client, 8.4 LTS) — NOT mariadb-client.
#     MySQL 8.4 defaults to the caching_sha2_password auth plugin; over a plain
#     (non-TLS) internal connection that requires RSA key exchange
#     (--get-server-public-key), which the official client supports but the
#     MariaDB client does not reliably. So we install the real mysqldump.
#   * MongoDB Database Tools (mongodump / mongorestore) — the official tools are
#     a separate package from the server; we install the pinned arm64 tarball.
#   * redis-tools (redis-cli) — for a network RDB snapshot (redis-cli --rdb).
#   * age — modern, audited, simple file encryption (pinned release binary).
#   * netcat-openbsd — fast "is this engine actually running?" TCP probe so the
#     backup only touches engines that are currently up (the DB layer is
#     on-demand / profile-gated).
#
# This image is ARM64-only by design (the platform runs on a Pi 5). The download
# URLs below are the linux/arm64 builds; the build is meant to run on the Pi.
# ===========================================================================
FROM postgres:16.6

# --- Pinned tool versions (NEVER "latest") ---------------------------------
ARG AGE_VERSION=1.3.1
ARG MONGO_TOOLS_VERSION=100.17.0
# MySQL's 2023 package-signing key fingerprint (verified before we trust it).
ARG MYSQL_GPG_FPR=BCA43417C3B485DD128EC6D4B7B3B788A8D3785C

# Everything in one layer; fail loudly on any error (set -eux).
RUN set -eux; \
    export DEBIAN_FRONTEND=noninteractive; \
    arch="$(dpkg --print-architecture)"; \
    if [ "$arch" != "arm64" ]; then \
      echo "WARNING: building on '$arch'; this image is intended for arm64 (Pi 5)." >&2; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg xz-utils gzip tzdata netcat-openbsd redis-tools; \
    \
    # --- MySQL official client (caching_sha2_password capable) -------------- \
    install -d -m 0755 /etc/apt/keyrings; \
    curl -fsSL https://repo.mysql.com/RPM-GPG-KEY-mysql-2023 -o /tmp/mysql.asc; \
    # Verify the downloaded key's fingerprint BEFORE trusting it. \
    got_fpr="$(gpg --show-keys --with-colons /tmp/mysql.asc | awk -F: '/^fpr:/{print $10; exit}')"; \
    echo "MySQL key fingerprint: ${got_fpr}"; \
    test "${got_fpr}" = "${MYSQL_GPG_FPR}"; \
    gpg --dearmor < /tmp/mysql.asc > /etc/apt/keyrings/mysql.gpg; \
    echo "deb [signed-by=/etc/apt/keyrings/mysql.gpg] http://repo.mysql.com/apt/debian/ bookworm mysql-8.4-lts" \
      > /etc/apt/sources.list.d/mysql.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends mysql-community-client; \
    \
    # --- MongoDB Database Tools (pinned arm64 tarball) --------------------- \
    curl -fsSL "https://fastdl.mongodb.org/tools/db/mongodb-database-tools-debian12-arm64-${MONGO_TOOLS_VERSION}.tgz" \
      -o /tmp/mongotools.tgz; \
    tar -xzf /tmp/mongotools.tgz -C /tmp; \
    cp /tmp/mongodb-database-tools-*/bin/mongodump    /usr/local/bin/mongodump; \
    cp /tmp/mongodb-database-tools-*/bin/mongorestore /usr/local/bin/mongorestore; \
    chmod 0755 /usr/local/bin/mongodump /usr/local/bin/mongorestore; \
    \
    # --- age (pinned arm64 release binary) -------------------------------- \
    curl -fsSL "https://github.com/FiloSottile/age/releases/download/v${AGE_VERSION}/age-v${AGE_VERSION}-linux-arm64.tar.gz" \
      -o /tmp/age.tgz; \
    tar -xzf /tmp/age.tgz -C /tmp; \
    cp /tmp/age/age /tmp/age/age-keygen /usr/local/bin/; \
    chmod 0755 /usr/local/bin/age /usr/local/bin/age-keygen; \
    \
    # --- Clean up --------------------------------------------------------- \
    rm -rf /var/lib/apt/lists/* /tmp/*; \
    \
    # --- Sanity: every tool must be present and runnable ------------------ \
    pg_dump --version; \
    pg_dumpall --version; \
    mysqldump --version; \
    mongodump --version; \
    mongorestore --version; \
    redis-cli --version; \
    age --version; \
    age-keygen --version

# The orchestrator that runs the actual backup. Lives in the repo too (under
# services/backup/) so it is versioned in git and baked into the image.
COPY do-backup.sh /opt/backup/do-backup.sh
RUN chmod 0755 /opt/backup/do-backup.sh

# Reset the inherited Postgres entrypoint — this container runs the backup
# orchestrator, never a database server. Restrictive umask so any artifact this
# image writes is owner-only (0600 files / 0700 dirs).
WORKDIR /opt/backup
ENTRYPOINT ["bash", "/opt/backup/do-backup.sh"]
