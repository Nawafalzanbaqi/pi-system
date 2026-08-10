// ===========================================================================
// __PROJECT_NAME__ (backend) — minimal .NET Web API for pi-system.
// REPLACES the base backend Program.cs when the bookings module is composed in:
// it keeps the base's /health and /api/info endpoints (the frontend calls the
// latter), and additionally wires the bookings API and applies its schema.
// ---------------------------------------------------------------------------
// Internal-only API. Reads its DB connection string from ConnectionStrings__Default
// (injected by the compose fragment from the shared "__DB_ENGINE__" credentials in
// .env). It publishes no host ports and is reached only by the frontend over the
// internal Docker network, as "__PROJECT_NAME__-api:8080".
// ===========================================================================
using Bookings;

var builder = WebApplication.CreateBuilder(args);

// bookings module — register its data access (reads ConnectionStrings:Default).
builder.Services.AddBookings();

var app = builder.Build();

// bookings module — apply the (idempotent) schema and seed first-run sample data.
// Guarded: a DB problem is logged but never prevents the API from starting.
try
{
    await BookingsMigrator.RunAsync(app.Configuration, app.Logger);
}
catch (Exception ex)
{
    app.Logger.LogError(ex, "bookings: schema setup failed; booking endpoints may be unavailable.");
}

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

// bookings module — list services, list available slots, create/confirm/cancel.
app.MapBookingsEndpoints();

app.Run();
