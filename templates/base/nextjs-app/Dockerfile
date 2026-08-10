# ===========================================================================
# __PROJECT_NAME__ — Next.js app (multi-stage, ARM64-friendly, standalone)
# ---------------------------------------------------------------------------
# Produces a small production image using Next.js "standalone" output. Node is
# pinned to the active LTS major (22) on Alpine — never "latest". For production
# you may pin an exact patch (e.g. node:22.x.y-alpine) or a digest.
# ===========================================================================
ARG NODE_TAG=22-alpine

# --- Dependencies ----------------------------------------------------------
FROM node:${NODE_TAG} AS deps
WORKDIR /app
# libc6-compat helps Next.js's native (SWC) binaries run on Alpine/musl (arm64).
RUN apk add --no-cache libc6-compat
COPY package.json package-lock.json* ./
# Use the lockfile when present (reproducible); fall back to install otherwise.
RUN if [ -f package-lock.json ]; then npm ci; else npm install; fi

# --- Build -----------------------------------------------------------------
FROM node:${NODE_TAG} AS build
WORKDIR /app
ENV NEXT_TELEMETRY_DISABLED=1
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

# Run as a dedicated non-root user.
RUN addgroup -S nodejs && adduser -S nextjs -G nodejs

# Standalone server bundle + static assets + public files.
COPY --from=build /app/public ./public
COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs
EXPOSE 3000

# Liveness check against the app's /health route (busybox wget ships in Alpine).
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health || exit 1

# Next.js standalone output emits server.js at the app root.
CMD ["node", "server.js"]
