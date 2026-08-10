// ===========================================================================
// __PROJECT_NAME__ — minimal .NET Web API for pi-system.
// ---------------------------------------------------------------------------
// Reads its database connection string from the environment variable
// ConnectionStrings__Default (injected by the compose fragment, built from the
// shared DB credentials in .env). Targets the "__DB_ENGINE__" engine, reached
// on the internal Docker network by service name. Publishes no host ports —
// Caddy fronts it at __SUBDOMAIN__.<BASE_DOMAIN>.
// ===========================================================================

var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

// Health endpoint required by the platform (Caddy / Uptime Kuma / Docker HEALTHCHECK).
app.MapGet("/health", () => Results.Ok(new { status = "healthy", service = "__PROJECT_NAME__" }));

// Root endpoint: reports basic info and whether a DB connection string was
// injected — WITHOUT ever echoing the connection string itself.
app.MapGet("/", (IConfiguration config) =>
{
    var connection = config.GetConnectionString("Default");
    return Results.Ok(new
    {
        service = "__PROJECT_NAME__",
        database = "__DB_ENGINE__",
        dbConfigured = !string.IsNullOrWhiteSpace(connection)
    });
});

app.Run();
