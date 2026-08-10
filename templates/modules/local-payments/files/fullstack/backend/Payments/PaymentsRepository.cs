// ===========================================================================
// pi-system module: local-payments — data access for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Talks to the PROJECT's own PostgreSQL database (ConnectionStrings:Default ->
// postgres:5432, built by the generator from the shared .env credentials). Uses
// Npgsql directly (one pinned, pure-managed dependency — ARM64-safe) with no ORM.
//
// IDEMPOTENCY (no double-credit) lives here: ApplyWebhookAsync locks the payment
// row (SELECT ... FOR UPDATE) and only moves pending -> paid ONCE, stamping paid_at
// a single time. A replayed/duplicate webhook finds the row already paid and is a
// no-op (AlreadyApplied). Concurrent webhooks for the same payment serialize on the
// row lock, so they can never both credit it.
//
// If the project's database is not PostgreSQL (--db mysql | mongo | none) the
// repository reports as unavailable and every operation returns a clear
// "unavailable" result instead of throwing — the API stays healthy. See the
// module README's "Database & fallbacks".
// ===========================================================================
using Npgsql;

namespace PiSystem.LocalPayments;

public sealed class PaymentsRepository : IAsyncDisposable
{
    private readonly NpgsqlDataSource? _db;

    public bool Available => _db is not null;

    public PaymentsRepository(IConfiguration config)
    {
        var cs = config.GetConnectionString("Default");
        if (IsPostgres(cs))
            _db = NpgsqlDataSource.Create(cs!);
    }

    /// <summary>PostgreSQL is detected by Npgsql's "Host=" keyword (the generator
    /// writes that form only for --db postgres).</summary>
    public static bool IsPostgres(string? cs)
        => !string.IsNullOrWhiteSpace(cs)
           && cs.Contains("Host=", StringComparison.OrdinalIgnoreCase);

    public async ValueTask DisposeAsync()
    {
        if (_db is not null) await _db.DisposeAsync();
    }

    // -- Create ---------------------------------------------------------------

    /// <summary>Persist a new pending payment intent and return it (with its public
    /// reference). Called BEFORE the provider create, so the reference can be sent
    /// to the provider as metadata + used in the callback URL.</summary>
    public async Task<PaymentDto?> CreatePendingAsync(
        long amountMinor, string currency, string description, string provider, CancellationToken ct = default)
    {
        if (_db is null) return null;
        var reference = NewReference();
        const string sql = @"
            INSERT INTO payments_payments (reference, provider, amount_minor, currency, description, status)
            VALUES (@ref, @provider, @amount, @currency, @desc, 'pending')
            RETURNING id, reference, provider, provider_payment_id, amount_minor, currency, status, description, created_at, paid_at";
        await using var cmd = _db.CreateCommand(sql);
        cmd.Parameters.AddWithValue("ref", reference);
        cmd.Parameters.AddWithValue("provider", provider);
        cmd.Parameters.AddWithValue("amount", amountMinor);
        cmd.Parameters.AddWithValue("currency", currency);
        cmd.Parameters.AddWithValue("desc", description);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct) ? Map(r) : null;
    }

    /// <summary>Record the provider's payment id (+ optional redirect URL) on an
    /// existing intent, after the provider create succeeds.</summary>
    public async Task AttachProviderAsync(
        string reference, string providerPaymentId, string? redirectUrl, CancellationToken ct = default)
    {
        if (_db is null) return;
        const string sql = @"
            UPDATE payments_payments
            SET provider_payment_id = @pid, redirect_url = @url, updated_at = now()
            WHERE reference = @ref";
        await using var cmd = _db.CreateCommand(sql);
        cmd.Parameters.AddWithValue("pid", providerPaymentId);
        cmd.Parameters.AddWithValue("url", (object?)redirectUrl ?? DBNull.Value);
        cmd.Parameters.AddWithValue("ref", reference);
        await cmd.ExecuteNonQueryAsync(ct);
    }

    // -- Read -----------------------------------------------------------------

    public async Task<PaymentDto?> GetByReferenceAsync(string reference, CancellationToken ct = default)
    {
        if (_db is null) return null;
        await using var cmd = _db.CreateCommand(Select + " WHERE reference = @ref");
        cmd.Parameters.AddWithValue("ref", reference);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct) ? Map(r) : null;
    }

    // -- Webhook (idempotent status transition) -------------------------------

    /// <summary>
    /// Apply a verified webhook to the matching payment, idempotently. pending->paid
    /// happens at most once (paid_at set once); replays are AlreadyApplied; backward
    /// or unknown transitions are Ignored. The row is locked FOR UPDATE so concurrent
    /// deliveries serialize — no double-credit.
    /// </summary>
    public async Task<WebhookApplyResult> ApplyWebhookAsync(
        string provider, string providerPaymentId, string newStatus, CancellationToken ct = default)
    {
        if (_db is null) return new WebhookApplyResult(WebhookOutcome.Unavailable, null);

        await using var conn = await _db.OpenConnectionAsync(ct);
        await using var tx = await conn.BeginTransactionAsync(ct);

        long id;
        string current;
        await using (var sel = new NpgsqlCommand(
            @"SELECT id, status FROM payments_payments
              WHERE provider = @provider AND provider_payment_id = @pid FOR UPDATE", conn, tx))
        {
            sel.Parameters.AddWithValue("provider", provider);
            sel.Parameters.AddWithValue("pid", providerPaymentId);
            await using var r = await sel.ExecuteReaderAsync(ct);
            if (!await r.ReadAsync(ct))
                return new WebhookApplyResult(WebhookOutcome.NotFound, null);
            id = r.GetInt64(0);
            current = r.GetString(1);
        }

        // Decide the (idempotent) transition.
        WebhookOutcome outcome;
        string? setStatus = null;
        bool setPaidAt = false;
        switch (newStatus)
        {
            case "paid":
                if (current == "paid") { outcome = WebhookOutcome.AlreadyApplied; }
                else if (current == "pending") { setStatus = "paid"; setPaidAt = true; outcome = WebhookOutcome.Applied; }
                else { outcome = WebhookOutcome.Ignored; }   // e.g. refunded -> paid: ignore
                break;
            case "failed":
                if (current == "pending") { setStatus = "failed"; outcome = WebhookOutcome.Applied; }
                else { outcome = WebhookOutcome.Ignored; }    // never override a paid/refunded payment
                break;
            case "refunded":
                if (current == "paid") { setStatus = "refunded"; outcome = WebhookOutcome.Applied; }
                else { outcome = WebhookOutcome.Ignored; }
                break;
            default:
                outcome = WebhookOutcome.Ignored;             // pending / unknown: nothing to do
                break;
        }

        if (setStatus is not null)
        {
            var sql = setPaidAt
                ? "UPDATE payments_payments SET status=@s, paid_at=now(), updated_at=now() WHERE id=@id AND status<>'paid'"
                : "UPDATE payments_payments SET status=@s, updated_at=now() WHERE id=@id";
            await using var upd = new NpgsqlCommand(sql, conn, tx);
            upd.Parameters.AddWithValue("s", setStatus);
            upd.Parameters.AddWithValue("id", id);
            await upd.ExecuteNonQueryAsync(ct);
        }

        await tx.CommitAsync(ct);

        var dto = await GetByReferenceByIdAsync(id, ct);
        return new WebhookApplyResult(outcome, dto);
    }

    // -- Helpers --------------------------------------------------------------

    private const string Select = @"
        SELECT id, reference, provider, provider_payment_id, amount_minor, currency,
               status, description, created_at, paid_at
        FROM payments_payments";

    private async Task<PaymentDto?> GetByReferenceByIdAsync(long id, CancellationToken ct)
    {
        if (_db is null) return null;
        await using var cmd = _db.CreateCommand(Select + " WHERE id = @id");
        cmd.Parameters.AddWithValue("id", id);
        await using var r = await cmd.ExecuteReaderAsync(ct);
        return await r.ReadAsync(ct) ? Map(r) : null;
    }

    private static PaymentDto Map(NpgsqlDataReader r) => new(
        r.GetInt64(0),                                              // id
        r.GetString(1),                                            // reference
        r.GetString(2),                                            // provider
        r.IsDBNull(3) ? null : r.GetString(3),                    // provider_payment_id
        r.GetInt64(4),                                            // amount_minor
        r.GetString(5),                                            // currency
        r.GetString(6),                                            // status
        r.GetString(7),                                            // description
        r.GetFieldValue<DateTime>(8),                             // created_at
        r.IsDBNull(9) ? null : r.GetFieldValue<DateTime>(9));     // paid_at

    private static string NewReference()
        => "PAY-" + Guid.NewGuid().ToString("N")[..10].ToUpperInvariant();
}
