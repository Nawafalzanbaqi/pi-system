# ===========================================================================
# control-api — Next.js API-only service (multi-stage, ARM64-friendly, standalone)
# ---------------------------------------------------------------------------
# The secure backend for the web control panel. API ONLY (route handlers under
# app/api) — it ships NO UI. Produces a small production image using Next.js
# "standalone" output. Node is pinned to the active LTS major (22) on Alpine —
# never "latest". For production you may pin an exact patch or a digest.
#
# HARD RULES (see infrastructure/docker-compose.yml): ARM64 image, multi-stage
# build, pinned base tags, NO secrets baked in (all config comes from .env at
# runtime), NO host ports (reached only via Caddy).
# ===========================================================================
ARG NODE_TAG=22-alpine

# --- Dependencies ----------------------------------------------------------
FROM node:${NODE_TAG} AS deps
WORKDIR /app
# libc6-compat helps Next.js's native (SWC) binaries run on Alpine/musl (arm64).
RUN apk add --no-cache libc6-compat
COPY package.json package-lock.json* ./
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# --- Build -----------------------------------------------------------------
FROM node:${NODE_TAG} AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
# Client-visible config is inlined by Next at build time. Default keeps the panel
# self-contained; override via compose build.args. NON-secret (a poll interval).
ARG NEXT_PUBLIC_CONTROL_PANEL_POLL_MS=5000
ENV NEXT_PUBLIC_CONTROL_PANEL_POLL_MS=${NEXT_PUBLIC_CONTROL_PANEL_POLL_MS}
COPY --from=deps /app/node_modules ./node_modules
COPY . ./
RUN npm run build

# --- Runtime ---------------------------------------------------------------
FROM node:${NODE_TAG} AS runtime
WORKDIR /app
ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME=0.0.0.0
# `ssh` is the constrained execution bridge to the host (forced-command); `wget`
# (busybox) backs the healthcheck. openssh-client is the only extra package.
RUN apk add --no-cache openssh-client

# Run as a dedicated non-root user (compose may override the UID so it can write
# the bind-mounted .env — see control-api.compose.yml).
RUN addgroup -S nodejs && adduser -S nextjs -G nodejs

# Standalone server bundle + static assets + public files.
COPY --from=build /app/public ./public
COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static
# The config registry is read at RUNTIME via fs (Next does not trace runtime
# reads), so copy it to a fixed path the loader knows about (/app/config-registry.json).
COPY --from=build --chown=nextjs:nodejs /app/config-registry.json ./config-registry.json

USER nextjs
EXPOSE 3000

# Liveness against the PUBLIC /api/health route (busybox wget ships in Alpine).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/api/health || exit 1

# Next.js standalone output emits server.js at the app root.
CMD ["node", "server.js"]
