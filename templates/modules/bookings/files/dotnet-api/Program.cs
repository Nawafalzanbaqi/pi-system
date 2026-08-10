// ===========================================================================
// __PROJECT_NAME__ — minimal .NET Web API for pi-system.
// REPLACES the base Program.cs when the bookings module is composed in: it keeps
// the base's /health and / endpoints, and additionally wires the bookings API and
// applies its schema on startup.
// ---------------------------------------------------------------------------
// Reads its database connection string from ConnectionStrings__Default (injected
// by the compose fragment, built from the shared DB credentials in .env). Targets
// the "__DB_ENGINE__" engine, reached on the internal Docker network by service
// name. Publishes no host ports — Caddy fronts it at __SUBDOMAIN__.<BASE_DOMAIN>.
// ===========================================================================
using Bookings;

var builder = WebApplication.CreateBuilder(args);

// bookings module — register its data access (reads ConnectionStrings:Default).
builder.Services.AddBookings();

var app = builder.Build();

// bookings module — apply the (idempotent) schema and seed first-run sample data.
// Guarded: a DB problem is logged but never prevents the API from starting, so
// /health stays up even if the database is missing or not yet ready.
try
{
    await BookingsMigrator.RunAsync(app.Configuration, app.Logger);
}
catch (Exception ex)
{
    app.Logger.LogError(ex, "bookings: schema setup failed; booking endpoints may be unavailable.");
}

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

// bookings module — list services, list available slots, create/confirm/cancel.
app.MapBookingsEndpoints();

app.Run();
