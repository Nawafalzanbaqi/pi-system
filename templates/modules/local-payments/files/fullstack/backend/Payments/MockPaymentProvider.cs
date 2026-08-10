// ===========================================================================
// pi-system module: local-payments — the MOCK provider (DEFAULT) for
// "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Active whenever PAYMENTS_PROVIDER is blank or "mock" (the default). It simulates
// the ENTIRE payment lifecycle locally — create an intent, "pay" it (via the
// /api/payments/mock/pay/{reference} endpoint), which emits an HMAC-SIGNED webhook
// that the same verification + idempotent recording path the real provider uses
// then processes to mark the payment paid. So the full flow (and the webhook
// signature check, and idempotency) is exercisable RIGHT NOW with no merchant
// account. Flip PAYMENTS_PROVIDER=moyasar (with credentials) for real payments;
// nothing else in the app changes.
// ===========================================================================
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace PiSystem.LocalPayments;

public sealed class MockPaymentProvider : IPaymentProvider
{
    // Used to sign the simulated webhook when PAYMENTS_WEBHOOK_SECRET is blank, so
    // the mock works out of the box AND still demonstrates real HMAC verification.
    public const string DefaultWebhookSecret = "pi-mock-webhook-secret";
    public const string SignatureHeader = "X-Mock-Signature";

    private readonly IConfiguration _config;
    private readonly ILogger<MockPaymentProvider> _logger;

    public MockPaymentProvider(IConfiguration config, ILogger<MockPaymentProvider> logger)
    {
        _config = config;
        _logger = logger;
    }

    public string ProviderName => "mock";
    public bool Configured => true;

    public Task<ProviderCreateResult> CreateAsync(ProviderCreateRequest req, CancellationToken ct = default)
    {
        // No external call. Mint a synthetic provider id; the "payment page" is the
        // in-app simulate-pay endpoint, so there is no external redirect URL.
        var id = "mock_pay_" + Guid.NewGuid().ToString("N")[..16];
        _logger.LogInformation(
            "payments(mock): created intent ref={Ref} amount={Amount} {Currency} id={Id}",
            req.Reference, req.AmountMinor, req.Currency, id);
        return Task.FromResult(ProviderCreateResult.Ok(id, redirectUrl: null));
    }

    public bool VerifyWebhook(string rawBody, IHeaderDictionary headers)
    {
        var provided = headers[SignatureHeader].ToString();
        var secret = ResolveSecret(_config);
        return VerifySignature(rawBody, secret, provided);
    }

    public WebhookEvent? ParseWebhook(string rawBody)
    {
        try
        {
            using var doc = JsonDocument.Parse(rawBody);
            var root = doc.RootElement;
            var id = root.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
            var status = root.TryGetProperty("status", out var stEl) ? stEl.GetString() : null;
            if (string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(status)) return null;
            return new WebhookEvent(id!, Normalize(status!));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    // ---- Shared helpers used by the mock-pay endpoint to emit a signed webhook ----

    /// <summary>The secret the mock signs/verifies with (PAYMENTS_WEBHOOK_SECRET or a dev default).</summary>
    public static string ResolveSecret(IConfiguration config)
    {
        var s = (config["PAYMENTS_WEBHOOK_SECRET"] ?? string.Empty).Trim();
        return s.Length > 0 ? s : DefaultWebhookSecret;
    }

    /// <summary>Compute the "sha256=&lt;hex&gt;" signature for a raw body (HMAC-SHA256).</summary>
    public static string ComputeSignature(string secret, string rawBody)
    {
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(secret));
        var hex = Convert.ToHexString(hmac.ComputeHash(Encoding.UTF8.GetBytes(rawBody))).ToLowerInvariant();
        return "sha256=" + hex;
    }

    private static bool VerifySignature(string rawBody, string secret, string signatureHeader)
    {
        const string prefix = "sha256=";
        if (string.IsNullOrEmpty(signatureHeader) || !signatureHeader.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            return false;
        var expected = ComputeSignature(secret, rawBody);
        var a = Encoding.UTF8.GetBytes(signatureHeader.Trim().ToLowerInvariant());
        var b = Encoding.UTF8.GetBytes(expected);
        return a.Length == b.Length && CryptographicOperations.FixedTimeEquals(a, b);
    }

    private static string Normalize(string status) => status.Trim().ToLowerInvariant() switch
    {
        "paid" or "succeeded" or "captured" => "paid",
        "failed" or "voided" or "declined" => "failed",
        "refunded" => "refunded",
        _ => "pending",
    };
}
