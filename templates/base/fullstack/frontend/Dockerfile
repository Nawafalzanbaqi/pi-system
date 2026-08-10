# ===========================================================================
# __PROJECT_NAME__ (frontend) — Next.js app (multi-stage, ARM64, standalone)
# ---------------------------------------------------------------------------
# Web-facing frontend for the __PROJECT_NAME__ full-stack project. Talks to the
# .NET backend over the internal network (BACKEND_URL). Node pinned to the
# active LTS major (22) on Alpine — never "latest". Pin a patch/digest for prod.
# ===========================================================================
ARG NODE_TAG=22-alpine

# --- Dependencies ----------------------------------------------------------
FROM node:${NODE_TAG} AS deps
WORKDIR /app
RUN apk add --no-cache libc6-compat
COPY package.json package-lock.json* ./
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
RUN addgroup -S nodejs && adduser -S nextjs -G nodejs
COPY --from=build /app/public ./public
COPY --from=build --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=build --chown=nextjs:nodejs /app/.next/static ./.next/static
USER nextjs
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD wget -qO- http://127.0.0.1:3000/health || exit 1
CMD ["node", "server.js"]
