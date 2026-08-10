// ===========================================================================
// pi-system module: bookings — HTTP API for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Minimal-API endpoints, wired into Program.cs via MapBookingsEndpoints(). They
// are thin: validation + the anti-double-booking logic live in BookingsRepository.
// Routes (under the service's existing host, fronted by Caddy — no new routes):
//
//   GET  /api/bookings/services                      list active services
//   GET  /api/bookings/services/{serviceId}/slots    available (future) slots
//   GET  /api/bookings/{id}                           fetch one booking
//   POST /api/bookings                                create a booking  (pending)
//   POST /api/bookings/{id}/confirm                  pending -> confirmed
//   POST /api/bookings/{id}/cancel                   -> cancelled (frees the slot)
// ===========================================================================
namespace Bookings;

public static class BookingsEndpoints
{
    /// <summary>Registers the bookings data access (reads ConnectionStrings:Default).</summary>
    public static IServiceCollection AddBookings(this IServiceCollection services)
    {
        // Singleton: it owns a pooled NpgsqlDataSource for the app's lifetime.
        services.AddSingleton<BookingsRepository>();
        return services;
    }

    public static WebApplication MapBookingsEndpoints(this WebApplication app)
    {
        app.MapGet("/api/bookings/services", async (BookingsRepository repo, CancellationToken ct) =>
            Results.Ok(await repo.GetServicesAsync(ct)));

        app.MapGet("/api/bookings/services/{serviceId:long}/slots",
            async (long serviceId, BookingsRepository repo, CancellationToken ct) =>
                Results.Ok(await repo.GetAvailableSlotsAsync(serviceId, ct)));

        app.MapGet("/api/bookings/{id:long}", async (long id, BookingsRepository repo, CancellationToken ct) =>
        {
            var booking = await repo.GetBookingAsync(id, ct);
            return booking is null ? Results.NotFound() : Results.Ok(booking);
        });

        app.MapPost("/api/bookings", async (CreateBookingRequest req, BookingsRepository repo, CancellationToken ct) =>
        {
            var res = await repo.CreateBookingAsync(req, ct);
            return res.Outcome switch
            {
                CreateOutcome.Created          => Results.Created($"/api/bookings/{res.Booking!.Id}", res.Booking),
                CreateOutcome.ValidationFailed => Results.BadRequest(new { error = res.Error }),
                CreateOutcome.SlotNotFound     => Results.NotFound(new { error = res.Error }),
                CreateOutcome.SlotUnavailable  => Results.Conflict(new { error = res.Error }),
                CreateOutcome.SlotFull         => Results.Conflict(new { error = res.Error }),
                CreateOutcome.Unavailable      => Results.Json(new { error = res.Error }, statusCode: 503),
                _                              => Results.Problem("Unknown error."),
            };
        });

        app.MapPost("/api/bookings/{id:long}/confirm", async (long id, BookingsRepository repo, CancellationToken ct) =>
            MapStatus(await repo.SetStatusAsync(id, "confirmed", ct)));

        app.MapPost("/api/bookings/{id:long}/cancel", async (long id, BookingsRepository repo, CancellationToken ct) =>
            MapStatus(await repo.SetStatusAsync(id, "cancelled", ct)));

        return app;
    }

    private static IResult MapStatus(StatusResult res) => res.Outcome switch
    {
        StatusChangeOutcome.Updated           => Results.Ok(res.Booking),
        StatusChangeOutcome.NotFound          => Results.NotFound(new { error = res.Error }),
        StatusChangeOutcome.InvalidTransition => Results.Conflict(new { error = res.Error }),
        StatusChangeOutcome.Unavailable       => Results.Json(new { error = res.Error }, statusCode: 503),
        _                                     => Results.Problem("Unknown error."),
    };
}
