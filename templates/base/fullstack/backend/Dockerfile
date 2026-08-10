# ===========================================================================
# __PROJECT_NAME__ (backend) — .NET Web API (multi-stage, ARM64-friendly)
# ---------------------------------------------------------------------------
# Internal-only API for the __PROJECT_NAME__ full-stack project. Built from the
# small ASP.NET Alpine runtime. Base images pinned to the current .NET LTS
# major (10.0) — never "latest". Pin an exact patch/digest for production.
# ===========================================================================
ARG DOTNET_SDK_TAG=10.0
ARG DOTNET_RUNTIME_TAG=10.0-alpine

# --- Build -----------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/sdk:${DOTNET_SDK_TAG} AS build
WORKDIR /src
COPY *.csproj ./
RUN dotnet restore
COPY . ./
RUN dotnet publish -c Release -o /app/publish /p:UseAppHost=false

# --- Runtime ---------------------------------------------------------------
FROM mcr.microsoft.com/dotnet/aspnet:${DOTNET_RUNTIME_TAG} AS runtime
WORKDIR /app
ENV ASPNETCORE_HTTP_PORTS=8080 \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true
COPY --from=build /app/publish ./
EXPOSE 8080
USER $APP_UID
HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
ENTRYPOINT ["dotnet", "app.dll"]
