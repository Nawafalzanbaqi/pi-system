# ===========================================================================
# pi-system — SEO/site-quality AUDITOR image (default engine: lightweight probe)
# ---------------------------------------------------------------------------
# A tiny, single-purpose ARM64 image carrying ONLY Node and the pure-Node audit
# engine (services/seo/engine). It is NOT a long-running service: it is launched as
# a one-shot container (by scripts/seo.sh, via `docker compose run --rm`) that
# fetches a configured site over HTTP, runs the deterministic on-page SEO /
# accessibility / best-practice checks, scores them, stores the result, and writes
# a rule-based recommendations report. When it finishes, NOTHING keeps running.
#
# WHY this (and NOT always-on headless Chromium/Lighthouse) — honest Pi reasoning:
#   * Headless Chromium is heavy on a Pi 5 (hundreds of MB of RAM + real CPU per
#     run). An always-on browser would permanently tax the device for a job that
#     runs a few times a day — exactly the always-on cost this platform avoids.
#   * So the DEFAULT engine is a pure-Node HTTP probe with NO browser: it needs
#     only Node (already the platform's Next.js runtime), starts in ~tens of ms,
#     and uses a tiny memory footprint. The heavier REAL Lighthouse engine is a
#     SEPARATE, OPT-IN image (Dockerfile.lighthouse) — never the default.
#
# HARD RULES (see infrastructure/docker-compose.yml):
#   * ARM64 (linux/arm64) only — Pi 5. node:22-alpine is multi-arch incl. arm64
#     (the SAME base the nextjs-app template builds from).
#   * Pinned tag. NEVER "latest".
#   * Runs as a non-root user; no secrets baked in (config + any optional AI key
#     come from the root .env at run time).
# ===========================================================================
FROM node:22-alpine

# The audit engine (pure Node, no npm dependencies — nothing to install).
WORKDIR /opt/seo
COPY engine/ /opt/seo/engine/

# Run as the image's built-in unprivileged "node" user; results are written to the
# mounted /data volume (host data/seo), which the run command makes writable.
USER node

# Default to the audit subcommand; scripts/seo.sh passes --name/--url/--engine.
ENTRYPOINT ["node", "/opt/seo/engine/audit.js"]
CMD ["list"]
