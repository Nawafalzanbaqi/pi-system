// ===========================================================================
// auth-sso — JWT bearer validation for "__PROJECT_NAME__" (.NET resource server).
// ---------------------------------------------------------------------------
// This file is ADDITIVE: it is layered onto the base by the auth-sso module and
// does NOT replace the base's Program.cs or app.csproj. It wires OIDC JWT bearer
// validation through an [assembly: HostingStartup], which the ASP.NET host runs
// during start-up when the service env sets:
//
//     ASPNETCORE_HOSTINGSTARTUPASSEMBLIES=app
//
// (the compose fragment sets this). Because it is a HostingStartup and not a
// Program.cs edit, auth-sso composes cleanly with modules that DO own Program.cs /
// app.csproj — notably `bookings`. The JwtBearer NuGet package is added by the
// sibling Directory.Build.props (also additive).
//
// What it does, from env (no secrets in code):
//   * OIDC_ISSUER_URL   the realm URL, e.g. https://auth.<domain>/realms/<realm>.
//                       The handler fetches {issuer}/.well-known/openid-configuration
//                       and the realm JWKS, then validates issuer + signing key.
//   * OIDC_AUDIENCE     expected "aud"; falls back to OIDC_CLIENT_ID; if still
//                       empty the audience check is skipped (issuer + signature +
//                       lifetime are always enforced). See SETUP.md (audience mapper).
//   * OIDC_REQUIRE_HTTPS_METADATA  default true; false only for local CA testing.
//
// Fail-closed: if OIDC_ISSUER_URL is blank the protected endpoint returns 503 and
// the rest of the API (e.g. /health, the base/bookings endpoints) keeps working —
// it is never left silently open.
// ===========================================================================
using System.Security.Claims;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.IdentityModel.Tokens;

[assembly: HostingStartup(typeof(PiSystem.AuthSso.OidcHostingStartup))]

namespace PiSystem.AuthSso;

public sealed class OidcHostingStartup : IHostingStartup
{
    public void Configure(IWebHostBuilder builder)
    {
        builder.ConfigureServices((context, services) =>
        {
            var config = context.Configuration;
            var issuer = config["OIDC_ISSUER_URL"]?.Trim();

            // No issuer -> auth is OFF. Register the example endpoint in a
            // fail-closed (503) mode so it never sits silently unprotected, and
            // skip the authentication stack entirely (the API still serves the
            // base/bookings endpoints + /health normally).
            if (string.IsNullOrWhiteSpace(issuer))
            {
                services.AddSingleton<IStartupFilter>(new ProtectedExampleEndpoint(authConfigured: false));
                return;
            }

            // Audience: explicit OIDC_AUDIENCE, else the project's own client id.
            var audience = config["OIDC_AUDIENCE"]?.Trim();
            if (string.IsNullOrWhiteSpace(audience)) audience = config["OIDC_CLIENT_ID"]?.Trim();
            var validateAudience = !string.IsNullOrWhiteSpace(audience);

            var requireHttps = config.GetValue("OIDC_REQUIRE_HTTPS_METADATA", true);

            services
                .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
                .AddJwtBearer(options =>
                {
                    options.Authority = issuer;                 // realm URL -> discovery + JWKS
                    options.RequireHttpsMetadata = requireHttps;
                    options.MapInboundClaims = false;           // keep original JWT claim names (sub, etc.)
                    options.TokenValidationParameters = new TokenValidationParameters
                    {
                        ValidateIssuer = true,
                        ValidIssuer = issuer,
                        ValidateAudience = validateAudience,
                        ValidAudience = audience,
                        ValidateIssuerSigningKey = true,        // signing key from the realm JWKS
                        ValidateLifetime = true,
                        ClockSkew = TimeSpan.FromSeconds(30),
                        NameClaimType = "preferred_username",
                        RoleClaimType = "roles",
                    };
                });
            services.AddAuthorization();

            // Registering authn/authz makes WebApplication auto-add the
            // UseAuthentication/UseAuthorization middleware (minimal-hosting), so
            // we do not touch Program.cs. The startup filter just adds the example
            // protected endpoint.
            services.AddSingleton<IStartupFilter>(new ProtectedExampleEndpoint(authConfigured: true));
        });
    }

    // ---------------------------------------------------------------------
    // Example protected endpoint: GET /api/me. Implemented as terminal
    // middleware (path branch) so it is independent of endpoint-routing order and
    // never collides with the base or bookings routes. It authenticates the
    // request against the JWT bearer scheme (full issuer/audience/signature/
    // lifetime validation) and returns the caller's claims, or 401 / 503.
    //
    // For an idiomatic minimal-API equivalent when YOU own Program.cs (a plain
    // dotnet-api project without bookings), see this module's README:
    //     app.MapGet("/api/me", (ClaimsPrincipal user) => ...).RequireAuthorization();
    // ---------------------------------------------------------------------
    private sealed class ProtectedExampleEndpoint : IStartupFilter
    {
        private readonly bool _authConfigured;
        public ProtectedExampleEndpoint(bool authConfigured) => _authConfigured = authConfigured;

        public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
        {
            app.Map("/api/me", branch => branch.Run(async ctx =>
            {
                ctx.Response.ContentType = "application/json; charset=utf-8";

                if (!_authConfigured)
                {
                    ctx.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
                    await ctx.Response.WriteAsync(
                        "{\"error\":\"OIDC is not configured (set OIDC_ISSUER_URL).\"}");
                    return;
                }

                var result = await ctx.AuthenticateAsync(JwtBearerDefaults.AuthenticationScheme);
                if (!result.Succeeded || result.Principal is null)
                {
                    ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                    ctx.Response.Headers.WWWAuthenticate = "Bearer";
                    await ctx.Response.WriteAsync(
                        "{\"error\":\"Unauthorized — a valid Bearer access token is required.\"}");
                    return;
                }

                var user = result.Principal;
                var payload = new
                {
                    sub = user.FindFirst("sub")?.Value,
                    username = user.FindFirst("preferred_username")?.Value,
                    email = user.FindFirst("email")?.Value,
                    name = user.FindFirst("name")?.Value,
                    roles = RealmRoles(user),
                };
                await ctx.Response.WriteAsync(JsonSerializer.Serialize(payload));
            }));

            next(app);
        };

        // Keycloak puts realm roles in a nested "realm_access":{"roles":[...]} claim.
        private static string[] RealmRoles(ClaimsPrincipal user)
        {
            var raw = user.FindFirst("realm_access")?.Value;
            if (string.IsNullOrWhiteSpace(raw)) return Array.Empty<string>();
            try
            {
                using var doc = JsonDocument.Parse(raw);
                if (doc.RootElement.TryGetProperty("roles", out var roles) &&
                    roles.ValueKind == JsonValueKind.Array)
                {
                    return roles.EnumerateArray()
                        .Where(e => e.ValueKind == JsonValueKind.String)
                        .Select(e => e.GetString()!)
                        .ToArray();
                }
            }
            catch (JsonException) { /* ignore malformed claim */ }
            return Array.Empty<string>();
        }
    }
}
