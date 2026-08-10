// ===========================================================================
// pi-system module: local-payments — startup schema setup for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// An IHostedService (additive — no Program.cs edit) that applies the IDEMPOTENT
// schema for the payments table against the project's PostgreSQL on startup. The
// SQL is embedded here (one small table) so there is no migrations-file copy step
// to coordinate with bookings' app.csproj.
//
// Fully guarded: if the database is not PostgreSQL or is unreachable it logs and
// returns — it NEVER throws into host start-up, so /health always comes up. The
// payment endpoints then report the feature unavailable rather than crashing (see
// PaymentsRepository). Registered by PaymentsHostingStartup.
// ===========================================================================
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace PiSystem.LocalPayments;

public sealed class PaymentsMigrator : IHostedService
{
    private readonly IConfiguration _config;
    private readonly ILogger<PaymentsMigrator> _logger;

    public PaymentsMigrator(IConfiguration config, ILogger<PaymentsMigrator> logger)
    {
        _config = config;
        _logger = logger;
    }

    // Idempotent (CREATE ... IF NOT EXISTS), so running it on every boot is safe.
    // Tables namespaced with a "payments_" prefix so they never collide with the
    // project's other tables (e.g. bookings_*) in the shared database.
    private const string SchemaSql = @"
CREATE TABLE IF NOT EXISTS payments_payments (
    id                  BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    reference           TEXT        NOT NULL UNIQUE,
    provider            TEXT        NOT NULL,
    provider_payment_id TEXT,
    amount_minor        BIGINT      NOT NULL CHECK (amount_minor > 0),
    currency            TEXT        NOT NULL DEFAULT 'SAR',
    status              TEXT        NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','paid','failed','refunded')),
    description         TEXT        NOT NULL DEFAULT '',
    redirect_url        TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
    paid_at             TIMESTAMPTZ
);

-- Idempotent webhook matching: a provider's payment id is unique once assigned, so
-- a (replayed) webhook resolves to exactly one row. This is the database-level
-- backstop behind the row-locked, transition-guarded ApplyWebhookAsync.
CREATE UNIQUE INDEX IF NOT EXISTS payments_provider_pid_uniq
    ON payments_payments (provider, provider_payment_id)
    WHERE provider_payment_id IS NOT NULL;

CREATE INDEX IF NOT EXISTS payments_status_idx ON payments_payments (status);
";

    public async Task StartAsync(CancellationToken ct)
    {
        try
        {
            var cs = _config.GetConnectionString("Default");
            if (!PaymentsRepository.IsPostgres(cs))
            {
                _logger.LogWarning(
                    "payments: no PostgreSQL connection on ConnectionStrings:Default. " +
                    "This module requires --db postgres; skipping schema setup. " +
                    "Payment endpoints will report that the feature is unavailable.");
                return;
            }

            await using var db = NpgsqlDataSource.Create(cs!);

            // The shared database is started separately, so bound-retry until ready.
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
                    _logger.LogInformation(
                        "payments: database not ready (attempt {Attempt}/{Max}): {Message}",
                        attempt, maxAttempts, ex.Message);
                    await Task.Delay(TimeSpan.FromSeconds(3), ct);
                }
            }

            await using (var cmd = db.CreateCommand(SchemaSql))
                await cmd.ExecuteNonQueryAsync(ct);
            _logger.LogInformation("payments: schema ensured (payments_payments).");
        }
        catch (Exception ex)
        {
            // Never block host start-up; the endpoints degrade gracefully.
            _logger.LogError(ex, "payments: schema setup failed; payment endpoints may be unavailable.");
        }
    }

    public Task StopAsync(CancellationToken ct) => Task.CompletedTask;
}
