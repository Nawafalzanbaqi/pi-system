# ===========================================================================
# __PROJECT_NAME__ — .NET Web API (multi-stage, ARM64-friendly)
# ---------------------------------------------------------------------------
# Build stage uses the .NET SDK; the runtime stage uses the small ASP.NET
# Alpine runtime so the final image stays lean on the Pi 5 (linux/arm64).
# Both base images are pinned to the current .NET LTS major (10.0) — never
# "latest". For production you may pin an exact patch (e.g. 10.0.x) or a digest.
# ===========================================================================
ARG DOTNET_SDK_TAG=10.0
ARG DOTNET_RUNTIME_TAG=10.0-alpine

# --- Build -----------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_TAG} AS build
WORKDIR /src

# Restore first so this layer is cached unless the project file changes.
COPY *.csproj ./
RUN dotnet restore

# Then bring in the rest of the source and publish a release build.
COPY . ./
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

# --- Runtime ---------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_RUNTIME_TAG} AS runtime
WORKDIR /app

# Listen on 8080 INSIDE the container only — no host port is published; Caddy
# fronts it over the `proxy` network. Invariant globalization keeps the Alpine
# image small and ICU-free (fine for a minimal API).
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true

COPY --from=build /app/publish ./
EXPOSE 8080

# Run as the non-root user the .NET base image provides (UID 1654).
USER $APP_UID

# Liveness check against the app's /health endpoint (busybox wget ships in the
# Alpine base image). The platform also probes /health via Caddy / Uptime Kuma.
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1

ENTRYPOINT ["dotnet", "app.dll"]
