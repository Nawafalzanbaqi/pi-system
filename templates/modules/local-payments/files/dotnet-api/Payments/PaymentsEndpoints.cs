// ===========================================================================
// pi-system module: local-payments — HTTP endpoints for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Registered as an IStartupFilter by PaymentsHostingStartup. Terminal middleware (a
// path branch) so it is independent of endpoint-routing order and never collides
// with the base / bookings / auth-sso / whatsapp routes — the approach auth-sso
// uses for /api/me.
//
// Routes (under the service's existing host, fronted by Caddy — no new routes):
//   POST /api/payments                    create a payment intent (returns reference + redirect)
//   GET  /api/payments/{reference}        current status of a payment
//   POST /api/payments/webhook            provider callback — VERIFIED, then recorded idempotently
//   POST /api/payments/mock/pay/{ref}     (mock provider only) simulate paying -> signed webhook
//   GET  /api/payments/_status            active provider + readiness (no secrets)
// ===========================================================================
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace PiSystem.LocalPayments;

public sealed class PaymentsEndpoints : IStartupFilter
{
    public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
    {
        app.Map("/api/payments", branch => branch.Run(async ctx =>
        {
            var path = ctx.Request.Path.Value ?? string.Empty;   // remainder after /api/payments
            var method = ctx.Request.Method;

            if ((path == "" || path == "/") && HttpMethods.IsPost(method)) { await Create(ctx); return; }
            if (path == "/_status" && HttpMethods.IsGet(method)) { await ProviderStatus(ctx); return; }
            if (path == "/webhook" && HttpMethods.IsPost(method)) { await Webhook(ctx); return; }
            if (path.StartsWith("/mock/pay/", StringComparison.Ordinal) && HttpMethods.IsPost(method))
            {
                await MockPay(ctx, path["/mock/pay/".Length..]); return;
            }
            // GET /api/payments/{reference}: single trailing segment, not a reserved word.
            if (HttpMethods.IsGet(method) && path.Length > 1 && path.IndexOf('/', 1) < 0)
            {
                await Status(ctx, path[1..]); return;
            }

            ctx.Response.StatusCode = StatusCodes.Status404NotFound;
        }));

        next(app);
    };

    // --- GET /api/payments/_status -------------------------------------------
    private static async Task ProviderStatus(HttpContext ctx)
    {
        var provider = ctx.RequestServices.GetRequiredService<IPaymentProvider>();
        var repo = ctx.RequestServices.GetRequiredService<PaymentsRepository>();
        await WriteJson(ctx, StatusCodes.Status200OK, new
        {
            provider = provider.ProviderName,
            configured = provider.Configured,
            databaseReady = repo.Available,
            note = provider.ProviderName == "mock"
                ? "Mock provider active — the full lifecycle is simulated locally. Set PAYMENTS_PROVIDER=moyasar with credentials to take real payments."
                : (provider.Configured
                    ? "Moyasar active and configured."
                    : "Moyasar selected but missing credentials — set PAYMENTS_API_KEY."),
        });
    }

    // --- POST /api/payments --------------------------------------------------
    private static async Task Create(HttpContext ctx)
    {
        var provider = ctx.RequestServices.GetRequiredService<IPaymentProvider>();
        var repo = ctx.RequestServices.GetRequiredService<PaymentsRepository>();
        var config = ctx.RequestServices.GetRequiredService<IConfiguration>();

        if (!repo.Available)
        {
            await WriteJson(ctx, StatusCodes.Status503ServiceUnavailable,
                new { error = "The payments database is not configured (this feature requires --db postgres)." });
            return;
        }

        CreatePaymentApiRequest? req;
        try
        {
            req = await JsonSerializer.DeserializeAsync<CreatePaymentApiRequest>(
                ctx.Request.Body, new JsonSerializerOptions(JsonSerializerDefaults.Web), ctx.RequestAborted);
        }
        catch (JsonException)
        {
            await WriteJson(ctx, StatusCodes.Status400BadRequest, new { error = "Invalid JSON body." });
            return;
        }

        var amount = req?.Amount ?? 0;
        if (amount <= 0)
        {
            await WriteJson(ctx, StatusCodes.Status400BadRequest,
                new { error = "\"amount\" (in the currency minor unit, e.g. halalas; > 0) is required." });
            return;
        }

        var currency = string.IsNullOrWhiteSpace(req?.Currency)
            ? (config["PAYMENTS_CURRENCY"]?.Trim() is { Length: > 0 } c ? c : "SAR")
            : req!.Currency!.Trim();
        var description = (req?.Description ?? string.Empty).Trim();

        // 1) Persist the pending intent first (so we have a reference for the provider).
        var pending = await repo.CreatePendingAsync(amount, currency, description, provider.ProviderName, ctx.RequestAborted);
        if (pending is null)
        {
            await WriteJson(ctx, StatusCodes.Status503ServiceUnavailable, new { error = "Could not create the payment intent." });
            return;
        }

        // 2) Ask the provider to create the payment, passing our reference + callback.
        var publicUrl = (config["PAYMENTS_PUBLIC_URL"] ?? string.Empty).TrimEnd('/');
        var callbackUrl = $"{publicUrl}/payment/return?ref={Uri.EscapeDataString(pending.Reference)}";
        var created = await provider.CreateAsync(
            new ProviderCreateRequest(pending.Reference, amount, currency, description, callbackUrl), ctx.RequestAborted);

        if (!created.Success)
        {
            await WriteJson(ctx, StatusCodes.Status502BadGateway,
                new { reference = pending.Reference, provider = provider.ProviderName, error = created.Error });
            return;
        }

        // 3) Record the provider's id (+ redirect URL) on the intent.
        await repo.AttachProviderAsync(pending.Reference, created.ProviderPaymentId!, created.RedirectUrl, ctx.RequestAborted);

        await WriteJson(ctx, StatusCodes.Status201Created, new
        {
            reference = pending.Reference,
            provider = provider.ProviderName,
            status = "pending",
            amount,
            currency,
            // Real providers return a hosted payment URL to navigate to. The mock has
            // none — instead it exposes an in-app endpoint to simulate paying.
            redirectUrl = created.RedirectUrl,
            mockPayUrl = provider.ProviderName == "mock" ? $"/api/payments/mock/pay/{pending.Reference}" : null,
        });
    }

    // --- GET /api/payments/{reference} ---------------------------------------
    private static async Task Status(HttpContext ctx, string reference)
    {
        var repo = ctx.RequestServices.GetRequiredService<PaymentsRepository>();
        if (!repo.Available)
        {
            await WriteJson(ctx, StatusCodes.Status503ServiceUnavailable,
                new { error = "The payments database is not configured (this feature requires --db postgres)." });
            return;
        }
        var dto = await repo.GetByReferenceAsync(Uri.UnescapeDataString(reference), ctx.RequestAborted);
        if (dto is null) { ctx.Response.StatusCode = StatusCodes.Status404NotFound; return; }
        await WriteJson(ctx, StatusCodes.Status200OK, dto);
    }

    // --- POST /api/payments/webhook ------------------------------------------
    private static async Task Webhook(HttpContext ctx)
    {
        var provider = ctx.RequestServices.GetRequiredService<IPaymentProvider>();
        var repo = ctx.RequestServices.GetRequiredService<PaymentsRepository>();
        var logger = ctx.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("payments.webhook");

        string raw;
        using (var reader = new StreamReader(ctx.Request.Body, Encoding.UTF8))
            raw = await reader.ReadToEndAsync(ctx.RequestAborted);

        // 1) Authenticate BEFORE trusting anything (signature / secret_token).
        if (!provider.VerifyWebhook(raw, ctx.Request.Headers))
        {
            logger.LogWarning("payments(webhook): rejected — failed verification ({Provider}).", provider.ProviderName);
            ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return;
        }

        await ApplyVerifiedWebhook(ctx, provider, repo, logger, raw);
    }

    // --- POST /api/payments/mock/pay/{reference} -----------------------------
    // Mock provider ONLY. Simulates the payer completing payment by EMITTING an
    // HMAC-signed webhook and running it through the SAME verify + record path the
    // real webhook uses — so the signature check + idempotency are genuinely
    // exercised with no external service. Returns the updated payment.
    private static async Task MockPay(HttpContext ctx, string reference)
    {
        var provider = ctx.RequestServices.GetRequiredService<IPaymentProvider>();
        var repo = ctx.RequestServices.GetRequiredService<PaymentsRepository>();
        var config = ctx.RequestServices.GetRequiredService<IConfiguration>();
        var logger = ctx.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("payments.mockpay");

        if (provider.ProviderName != "mock")
        {
            ctx.Response.StatusCode = StatusCodes.Status404NotFound;   // only meaningful for the mock
            return;
        }
        if (!repo.Available)
        {
            await WriteJson(ctx, StatusCodes.Status503ServiceUnavailable, new { error = "Payments database not configured." });
            return;
        }

        var dto = await repo.GetByReferenceAsync(Uri.UnescapeDataString(reference), ctx.RequestAborted);
        if (dto is null) { ctx.Response.StatusCode = StatusCodes.Status404NotFound; return; }
        if (string.IsNullOrWhiteSpace(dto.ProviderPaymentId))
        {
            await WriteJson(ctx, StatusCodes.Status409Conflict, new { error = "Payment has no provider id yet." });
            return;
        }

        // Build the webhook payload the mock provider understands, and sign it just
        // as a real provider would, using PAYMENTS_WEBHOOK_SECRET (or the dev default).
        var body = JsonSerializer.Serialize(new { id = dto.ProviderPaymentId, status = "paid", reference = dto.Reference });
        var signature = MockPaymentProvider.ComputeSignature(MockPaymentProvider.ResolveSecret(config), body);
        ctx.Request.Headers[MockPaymentProvider.SignatureHeader] = signature;

        if (!provider.VerifyWebhook(body, ctx.Request.Headers))
        {
            // Should never happen (we just signed it) — defensive.
            await WriteJson(ctx, StatusCodes.Status500InternalServerError, new { error = "Mock signature self-check failed." });
            return;
        }

        await ApplyVerifiedWebhook(ctx, provider, repo, logger, body);
    }

    // Shared path: parse a VERIFIED webhook, record it idempotently, ACK.
    private static async Task ApplyVerifiedWebhook(
        HttpContext ctx, IPaymentProvider provider, PaymentsRepository repo, ILogger logger, string raw)
    {
        var evt = provider.ParseWebhook(raw);
        if (evt is null)
        {
            await WriteJson(ctx, StatusCodes.Status400BadRequest, new { error = "Unparseable webhook payload." });
            return;
        }

        var result = await repo.ApplyWebhookAsync(provider.ProviderName, evt.ProviderPaymentId, evt.Status, ctx.RequestAborted);
        logger.LogInformation("payments(webhook): {Provider} pid={Pid} status={Status} -> {Outcome}",
            provider.ProviderName, evt.ProviderPaymentId, evt.Status, result.Outcome);

        switch (result.Outcome)
        {
            // 200 for applied + replayed (idempotent) so the provider stops retrying.
            case WebhookOutcome.Applied:
            case WebhookOutcome.AlreadyApplied:
            case WebhookOutcome.Ignored:
                await WriteJson(ctx, StatusCodes.Status200OK,
                    new { outcome = result.Outcome.ToString().ToLowerInvariant(), payment = result.Payment });
                break;
            case WebhookOutcome.NotFound:
                await WriteJson(ctx, StatusCodes.Status404NotFound, new { error = "No payment matches this event." });
                break;
            default:
                await WriteJson(ctx, StatusCodes.Status503ServiceUnavailable, new { error = "Payments database not configured." });
                break;
        }
    }

    private static async Task WriteJson(HttpContext ctx, int status, object payload)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json; charset=utf-8";
        await ctx.Response.WriteAsync(
            JsonSerializer.Serialize(payload, new JsonSerializerOptions(JsonSerializerDefaults.Web)), ctx.RequestAborted);
    }
}
