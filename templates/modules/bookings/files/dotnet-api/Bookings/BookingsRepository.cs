// ===========================================================================
// pi-system module: bookings — data access for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Talks to the PROJECT's own PostgreSQL database (ConnectionStrings:Default ->
// postgres:5432, built by the generator from the shared .env credentials). Uses
// Npgsql directly (one pinned, pure-managed dependency — ARM64-safe) with no ORM.
//
// ALL double-booking prevention lives here, SERVER-SIDE: CreateBookingAsync locks
// the slot row (SELECT ... FOR UPDATE) before counting active bookings, so two
// concurrent requests for the same slot serialize and can never both succeed. The
// partial unique index in 001_init_bookings.sql is the database-level backstop.
//
// If the project's database is not PostgreSQL (--db mysql | mongo | none), the
// repository reports as unavailable and every operation returns a clear
// "unavailable" result instead of throwing — the API stays healthy. See the
// module README's "Database & fallbacks".
// ===========================================================================
using Npgsql;

namespace Bookings;

public sealed class BookingsRepository : IAsyncDisposable
{
    private readonly NpgsqlDataSource? _db;

    /// <summary>True when a PostgreSQL connection is configured and usable.</summary>
    public bool Available => _db is not null;

    public BookingsRepository(IConfiguration config)
    {
        var cs = config.GetConnectionString("Default");
        if (IsPostgres(cs))
            _db = NpgsqlDataSource.Create(cs!);
    }

    /// <summary>
    /// The generator writes a Host=...-style string for --db postgres; mysql
    /// (Server=...), mongo (mongodb://...) and none (empty) are not relational
    /// targets for this module. Detect PostgreSQL by Npgsql's "Host=" keyword.
    /// </summary>
    public static bool IsPostgres(string? cs)
        => !string.IsNullOrWhiteSpace(cs)
           && cs.Contains("Host=", StringComparison.OrdinalIgnoreCase);

    public async ValueTask DisposeAsync()
    {
        if (_db is not null) await _db.DisposeAsync();
    }

    // -- Reads -----------------------------------------------------------------

    public async Task<IReadOnlyList<ServiceDto>> GetServicesAsync(CancellationToken ct = default)
    {
        if (_db is null) return Array.Empty<ServiceDto>();
        const string sql = @"
            SELECT id, slug, name_en, name_ar, description_en, description_ar, duration_minutes
            FROM bookings_services
            WHERE active
            ORDER BY name_en";
        var list = new List<ServiceDto>();
        await using var cmd = _db.CreateCommand(sql);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new ServiceDto(
                r.GetInt64(0), r.GetString(1), r.GetString(2), r.GetString(3),
                r.GetString(4), r.GetString(5), r.GetInt32(6)));
        }
        return list;
    }

    /// <summary>
    /// Future, active slots for a service whose remaining capacity (capacity minus
    /// non-cancelled bookings) is greater than zero — i.e. the bookable times.
    /// </summary>
    public async Task<IReadOnlyList<SlotDto>> GetAvailableSlotsAsync(long serviceId, CancellationToken ct = default)
    {
        if (_db is null) return Array.Empty<SlotDto>();
        const string sql = @"
            SELECT s.id, s.service_id, s.starts_at, s.ends_at, s.capacity,
                   s.capacity - COALESCE(b.active_count, 0) AS remaining
            FROM bookings_slots s
            LEFT JOIN (
                SELECT slot_id, COUNT(*) AS active_count
                FROM bookings_bookings
                WHERE status <> 'cancelled'
                GROUP BY slot_id
            ) b ON b.slot_id = s.id
            WHERE s.service_id = @sid
              AND s.active
              AND s.starts_at > now()
              AND s.capacity - COALESCE(b.active_count, 0) > 0
            ORDER BY s.starts_at";
        var list = new List<SlotDto>();
        await using var cmd = _db.CreateCommand(sql);
        cmd.Parameters.AddWithValue("sid", serviceId);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        while (await r.ReadAsync(ct))
        {
            list.Add(new SlotDto(
                r.GetInt64(0), r.GetInt64(1),
                r.GetFieldValue<DateTime>(2), r.GetFieldValue<DateTime>(3),
                r.GetInt32(4), r.GetInt32(5)));
        }
        return list;
    }

    public async Task<BookingDto?> GetBookingAsync(long id, CancellationToken ct = default)
    {
        if (_db is null) return null;
        await using var cmd = _db.CreateCommand(BookingSelect + " WHERE b.id = @id");
        cmd.Parameters.AddWithValue("id", id);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct) ? MapBooking(r) : null;
    }

    // -- Writes ----------------------------------------------------------------

    /// <summary>
    /// Create a booking against a slot, preventing double-booking. The slot row is
    /// locked FOR UPDATE so concurrent attempts on the same slot serialize; only
    /// while fewer than `capacity` active bookings exist does the insert proceed.
    /// </summary>
    public async Task<CreateResult> CreateBookingAsync(CreateBookingRequest req, CancellationToken ct = default)
    {
        if (_db is null)
            return new CreateResult(CreateOutcome.Unavailable, null,
                "The bookings database is not configured (this feature requires --db postgres).");

        // Validate server-side — never trust the UI.
        var name = (req.CustomerName ?? string.Empty).Trim();
        var email = (req.CustomerEmail ?? string.Empty).Trim();
        var phone = (req.CustomerPhone ?? string.Empty).Trim();
        var notes = (req.Notes ?? string.Empty).Trim();
        if (req.SlotId <= 0 || name.Length == 0 || !LooksLikeEmail(email))
            return new CreateResult(CreateOutcome.ValidationFailed, null,
                "slotId, customerName and a valid customerEmail are required.");

        await using var conn = await _db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        // Lock the slot row: this serializes concurrent bookings for the SAME slot,
        // making the capacity check below race-free.
        long slotServiceId;
        int capacity;
        bool active;
        DateTime startsAt;
        await using (var slotCmd = new NpgsqlCommand(
            @"SELECT service_id, capacity, active, starts_at
              FROM bookings_slots WHERE id = @id FOR UPDATE", conn, tx))
        {
            slotCmd.Parameters.AddWithValue("id", req.SlotId);
            await using var sr = await slotCmd.ExecuteReaderAsync(ct);
            if (!await sr.ReadAsync(ct))
                return new CreateResult(CreateOutcome.SlotNotFound, null, "Slot not found.");
            slotServiceId = sr.GetInt64(0);
            capacity = sr.GetInt32(1);
            active = sr.GetBoolean(2);
            startsAt = sr.GetFieldValue<DateTime>(3);
        }

        if (!active || startsAt <= DateTime.UtcNow)
            return new CreateResult(CreateOutcome.SlotUnavailable, null,
                "That time slot is no longer available.");

        long activeCount;
        await using (var cntCmd = new NpgsqlCommand(
            @"SELECT COUNT(*) FROM bookings_bookings
              WHERE slot_id = @id AND status <> 'cancelled'", conn, tx))
        {
            cntCmd.Parameters.AddWithValue("id", req.SlotId);
            activeCount = (long)(await cntCmd.ExecuteScalarAsync(ct))!;
        }
        if (activeCount >= capacity)
            return new CreateResult(CreateOutcome.SlotFull, null,
                "That time slot is fully booked.");

        var reference = NewReference();
        long newId;
        await using (var insCmd = new NpgsqlCommand(
            @"INSERT INTO bookings_bookings
                (reference, slot_id, service_id, customer_name, customer_email,
                 customer_phone, notes, status)
              VALUES (@ref, @slot, @svc, @name, @email, @phone, @notes, 'pending')
              RETURNING id", conn, tx))
        {
            insCmd.Parameters.AddWithValue("ref", reference);
            insCmd.Parameters.AddWithValue("slot", req.SlotId);
            insCmd.Parameters.AddWithValue("svc", slotServiceId);
            insCmd.Parameters.AddWithValue("name", name);
            insCmd.Parameters.AddWithValue("email", email);
            insCmd.Parameters.AddWithValue("phone", phone);
            insCmd.Parameters.AddWithValue("notes", notes);
            newId = (long)(await insCmd.ExecuteScalarAsync(ct))!;
        }

        await tx.CommitAsync(ct);

        var dto = await GetBookingAsync(newId, ct);
        return new CreateResult(CreateOutcome.Created, dto, null);
    }

    /// <summary>
    /// Move a booking to confirmed or cancelled. Valid transitions:
    /// pending -> confirmed; pending/confirmed -> cancelled. Cancelling frees the
    /// slot (the partial unique index ignores cancelled rows).
    /// </summary>
    public async Task<StatusResult> SetStatusAsync(long id, string newStatus, CancellationToken ct = default)
    {
        if (_db is null)
            return new StatusResult(StatusChangeOutcome.Unavailable, null,
                "The bookings database is not configured (this feature requires --db postgres).");

        await using var conn = await _db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        string current;
        await using (var cmd = new NpgsqlCommand(
            "SELECT status FROM bookings_bookings WHERE id = @id FOR UPDATE", conn, tx))
        {
            cmd.Parameters.AddWithValue("id", id);
            var res = await cmd.ExecuteScalarAsync(ct);
            if (res is null)
                return new StatusResult(StatusChangeOutcome.NotFound, null, "Booking not found.");
            current = (string)res;
        }

        var allowed = newStatus switch
        {
            "confirmed" => current == "pending",
            "cancelled" => current != "cancelled",
            _ => false,
        };
        if (!allowed)
            return new StatusResult(StatusChangeOutcome.InvalidTransition, null,
                $"Cannot change a '{current}' booking to '{newStatus}'.");

        await using (var upd = new NpgsqlCommand(
            "UPDATE bookings_bookings SET status = @s, updated_at = now() WHERE id = @id", conn, tx))
        {
            upd.Parameters.AddWithValue("s", newStatus);
            upd.Parameters.AddWithValue("id", id);
            await upd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);

        var dto = await GetBookingAsync(id, ct);
        return new StatusResult(StatusChangeOutcome.Updated, dto, null);
    }

    // -- Helpers ---------------------------------------------------------------

    private const string BookingSelect = @"
        SELECT b.id, b.reference, b.slot_id, b.service_id, b.customer_name,
               b.customer_email, b.customer_phone, b.notes, b.status, b.created_at,
               s.starts_at, s.ends_at
        FROM bookings_bookings b
        JOIN bookings_slots s ON s.id = b.slot_id";

    private static BookingDto MapBooking(NpgsqlDataReader r) => new(
        r.GetInt64(0),                    // id
        r.GetString(1),                   // reference
        r.GetInt64(2),                    // slot_id
        r.GetInt64(3),                    // service_id
        r.GetString(4),                   // customer_name
        r.GetString(5),                   // customer_email
        r.GetString(6),                   // customer_phone
        r.GetString(7),                   // notes
        r.GetString(8),                   // status
        r.GetFieldValue<DateTime>(10),    // starts_at  (from the slot join)
        r.GetFieldValue<DateTime>(11),    // ends_at
        r.GetFieldValue<DateTime>(9));    // created_at

    // Minimal, dependency-free email sanity check (a non-empty local part, an '@',
    // and a '.' somewhere after it). Real validation happens when you email them.
    private static bool LooksLikeEmail(string s)
    {
        var at = s.IndexOf('@');
        return at > 0 && at < s.Length - 1 && s.IndexOf('.', at) > at;
    }

    private static string NewReference()
        => "BK-" + Guid.NewGuid().ToString("N")[..8].ToUpperInvariant();
}
