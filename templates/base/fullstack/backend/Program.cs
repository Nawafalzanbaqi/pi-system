// ===========================================================================
// __PROJECT_NAME__ (backend) — minimal .NET Web API for pi-system.
// ---------------------------------------------------------------------------
// Internal-only API. Reads its DB connection string from the environment
// variable ConnectionStrings__Default (injected by the compose fragment from
// the shared "__DB_ENGINE__" credentials in .env). It publishes no host ports
// and is reached only by the frontend over the internal Docker network, as
// "__PROJECT_NAME__-api:8080".
// ===========================================================================

var builder = WebApplication.CreateBuilder(args);

var app = builder.Build();

// Health endpoint (the frontend surfaces this; also used by Docker HEALTHCHECK).
app.MapGet("/health", () => Results.Ok(new { status = "healthy", service = "__PROJECT_NAME__-api" }));

// Sample API endpoint consumed by the frontend.
app.MapGet("/api/info", (IConfiguration config) =>
{
    var connection = config.GetConnectionString("Default");
    return Results.Ok(new
    {
        service = "__PROJECT_NAME__-api",
        database = "__DB_ENGINE__",
        dbConfigured = !string.IsNullOrWhiteSpace(connection)
    });
});

app.Run();
