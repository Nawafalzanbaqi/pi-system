// ===========================================================================
// pi-system module: bookings — startup schema setup for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Applies the idempotent SQL migrations in Bookings/migrations/*.sql against the
// project's PostgreSQL database, then (on a brand-new install only) seeds a little
// sample data so the booking flow works end-to-end out of the box.
//
// Runs ONCE at startup. It is fully guarded: if the database is not PostgreSQL or
// is unreachable, it logs and returns — it NEVER throws into the host, so the
// API's /health endpoint always comes up. The booking endpoints then report the
// feature as unavailable rather than crashing (see BookingsRepository).
// ===========================================================================
using Npgsql;

namespace Bookings;

public static class BookingsMigrator
{
    public static async Task RunAsync(IConfiguration config, ILogger logger, CancellationToken ct = default)
    {
        var cs = config.GetConnectionString("Default");
        if (!BookingsRepository.IsPostgres(cs))
        {
            logger.LogWarning(
                "bookings: no PostgreSQL connection on ConnectionStrings:Default. " +
                "This module requires --db postgres; skipping schema setup. " +
                "Booking endpoints will report that the feature is unavailable.");
            return;
        }

        await using var db = NpgsqlDataSource.Create(cs!);

        // The shared database is started separately (not via depends_on), so it
        // may not be ready the instant this app boots — retry a bounded number of
        // times, then give up gracefully (the app still starts).
        const int maxAttempts = 10;
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await using var probe = await db.OpenConnectionAsync(ct);
                break;
            }
            catch (Exception ex) when (attempt < maxAttempts)
            {
                logger.LogInformation(
                    "bookings: database not ready (attempt {Attempt}/{Max}): {Message}",
                    attempt, maxAttempts, ex.Message);
                await Task.Delay(TimeSpan.FromSeconds(3), ct);
            }
        }

        // Apply each *.sql migration in filename order. They are idempotent
        // (CREATE ... IF NOT EXISTS), so running them on every boot is safe.
        var dir = Path.Combine(AppContext.BaseDirectory, "Bookings", "migrations");
        if (Directory.Exists(dir))
        {
            foreach (var file in Directory.GetFiles(dir, "*.sql").OrderBy(f => f, StringComparer.Ordinal))
            {
                var sql = await File.ReadAllTextAsync(file, ct);
                await using var cmd = db.CreateCommand(sql);
                await cmd.ExecuteNonQueryAsync(ct);
                logger.LogInformation("bookings: applied migration {File}", Path.GetFileName(file));
            }
        }
        else
        {
            logger.LogWarning("bookings: migrations directory not found at {Dir} — schema not applied.", dir);
        }

        await MaybeSeedAsync(db, config, logger, ct);
    }

    // First-run sample data so the flow is demonstrable immediately. Runs ONLY
    // when the services table is empty, and never if BOOKINGS_SEED=false. It never
    // touches existing data, so production installs that add real services (or set
    // BOOKINGS_SEED=false) simply never seed.
    private static async Task MaybeSeedAsync(NpgsqlDataSource db, IConfiguration config, ILogger logger, CancellationToken ct)
    {
        if (string.Equals(config["BOOKINGS_SEED"], "false", StringComparison.OrdinalIgnoreCase))
            return;

        long count;
        await using (var cmd = db.CreateCommand("SELECT COUNT(*) FROM bookings_services"))
            count = (long)(await cmd.ExecuteScalarAsync(ct))!;
        if (count > 0) return;

        logger.LogInformation("bookings: empty install — seeding sample services + upcoming slots (set BOOKINGS_SEED=false to disable).");

        // Two generic, bilingual sample services. Replace or delete them in your DB.
        var services = new (string Slug, string En, string Ar, string DescEn, string DescAr, int Mins)[]
        {
            ("consultation",     "Consultation",     "استشارة",      "A standard 30-minute consultation.", "استشارة قياسية مدتها 30 دقيقة.", 30),
            ("extended-session", "Extended session", "جلسة موسعة",  "A longer 60-minute session.",        "جلسة أطول مدتها 60 دقيقة.",     60),
        };

        var today = DateTime.UtcNow.Date;
        foreach (var s in services)
        {
            long serviceId;
            await using (var cmd = db.CreateCommand(@"
                INSERT INTO bookings_services
                    (slug, name_en, name_ar, description_en, description_ar, duration_minutes)
                VALUES (@slug, @en, @ar, @den, @dar, @mins)
                ON CONFLICT (slug) DO UPDATE SET slug = EXCLUDED.slug
                RETURNING id"))
            {
                cmd.Parameters.AddWithValue("slug", s.Slug);
                cmd.Parameters.AddWithValue("en", s.En);
                cmd.Parameters.AddWithValue("ar", s.Ar);
                cmd.Parameters.AddWithValue("den", s.DescEn);
                cmd.Parameters.AddWithValue("dar", s.DescAr);
                cmd.Parameters.AddWithValue("mins", s.Mins);
                serviceId = (long)(await cmd.ExecuteScalarAsync(ct))!;
            }

            // Upcoming slots: the next 7 days, 09:00–16:00 UTC, one per hour.
            // Idempotent against the (service_id, starts_at) unique constraint.
            for (var day = 1; day <= 7; day++)
            {
                var date = today.AddDays(day);
                for (var hour = 9; hour < 16; hour++)
                {
                    var start = DateTime.SpecifyKind(date.AddHours(hour), DateTimeKind.Utc);
                    var end = start.AddMinutes(s.Mins);
                    await using var cmd = db.CreateCommand(@"
                        INSERT INTO bookings_slots (service_id, starts_at, ends_at)
                        VALUES (@svc, @start, @end)
                        ON CONFLICT (service_id, starts_at) DO NOTHING");
                    cmd.Parameters.AddWithValue("svc", serviceId);
                    cmd.Parameters.AddWithValue("start", start);
                    cmd.Parameters.AddWithValue("end", end);
                    await cmd.ExecuteNonQueryAsync(ct);
                }
            }
        }

        logger.LogInformation("bookings: seeded {Count} sample services with upcoming slots.", services.Length);
    }
}
