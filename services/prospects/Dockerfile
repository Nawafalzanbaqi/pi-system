# ===========================================================================
# pi-system — CLIENT PROSPECT ORGANIZER image (operator-owned CRM-lite)
# ---------------------------------------------------------------------------
# A tiny, single-purpose ARM64 image carrying ONLY Node and two pure-Node engines:
#   * the prospect organizer engine (services/prospects/engine), and
#   * the EXISTING SEO engine (services/seo/engine) it REUSES for public-site
#     analysis — copied in so analyze.js can `import` it directly (no parallel
#     analyzer, no duplicated probe/rules/report code).
#
# It is NOT a long-running service: it is launched as a one-shot container (by
# scripts/prospects.sh via `docker compose run --rm`) that reads/writes the
# operator's prospect pipeline under /data, optionally fetches ONE prospect's OWN
# public website to produce a report, and exits. When it finishes, NOTHING keeps
# running — zero RAM when idle, the same Pi-aware design the SEO auditor uses.
#
# ETHICAL/LEGAL BOUNDARY (architectural): this image contains NO scraper of any
# platform (no Google Maps / LinkedIn / search integration) and NO outreach
# transport (no SMTP / WhatsApp / bulk-send). It organizes operator-entered data
# and analyzes a prospect's own public site only. See services/prospects/README.md.
#
# Build context is ./services (see prospects.compose.yml) so BOTH engine trees are
# available; the relative import `../../seo/engine/...` resolves identically here
# (/opt/app/{prospects,seo}/engine) and in the repo (services/{prospects,seo}/engine).
#
# HARD RULES (see infrastructure/docker-compose.yml):
#   * ARM64 (linux/arm64) only — Pi 5. node:22-alpine is multi-arch incl. arm64
#     (the SAME pinned base the SEO auditor + nextjs-app template build from).
#   * Pinned tag. NEVER "latest".
#   * Runs as the unprivileged "node" user; no secrets baked in (config + any
#     optional AI key come from the root .env at run time).
# ===========================================================================
FROM node:22-alpine

WORKDIR /opt/app

# The REUSED SEO engine (pure Node, no npm deps) + the prospect organizer engine.
# Layout is preserved so analyze.js's `../../seo/engine` import resolves at runtime.
COPY seo/engine/ /opt/app/seo/engine/
COPY prospects/engine/ /opt/app/prospects/engine/

# Run as the image's built-in unprivileged "node" user; results are written to the
# mounted /data volume (host data/prospects), which the run command makes writable.
USER node

# Default to listing the pipeline; scripts/prospects.sh passes the real subcommand.
ENTRYPOINT ["node", "/opt/app/prospects/engine/prospects.js"]
CMD ["list"]
