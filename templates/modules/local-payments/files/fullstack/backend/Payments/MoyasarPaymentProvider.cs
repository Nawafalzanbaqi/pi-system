// ===========================================================================
// pi-system module: local-payments — the REAL provider for "__PROJECT_NAME__":
// Moyasar (https://moyasar.com), a Saudi payment gateway.
// ---------------------------------------------------------------------------
// Why Moyasar: it is a well-documented Saudi gateway with a simple public REST API
// and supports the methods the local market needs — **mada**, Apple Pay, and
// credit/debit cards — through a single hosted-invoice flow (no card data touches
// this server). (HyperPay is the other common choice; its COPYandPAY flow is
// heavier to integrate. Moyasar keeps this module self-contained while still being
// a genuine, production-grade integration.)
//
// Flow used here = the Invoices API (server-side, redirect-based):
//   POST https://api.moyasar.com/v1/invoices   (HTTP Basic auth: secret key)
//   { amount(halalas), currency, description, callback_url, metadata }
//   -> { "id": "inv_...", "url": "https://.../invoice/...", ... }
// The payer is sent to `url`, pays with mada/Apple Pay/card on Moyasar's hosted
// page, and is returned to `callback_url`. Settlement is confirmed by the WEBHOOK
// (not the redirect), which carries a `secret_token` we verify.
//
// Selected ONLY when PAYMENTS_PROVIDER=moyasar. INERT until PAYMENTS_API_KEY is set:
// Configured is false and CreateAsync returns an error instead of calling out — so
// the real provider is "fully coded but dormant until env is set". No SDK — built-in
// HttpClient + System.Text.Json only (ARM64-safe).
// ===========================================================================
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace PiSystem.LocalPayments;

public sealed class MoyasarPaymentProvider : IPaymentProvider
{
    private const string ApiBase = "https://api.moyasar.com/v1";

    private readonly IHttpClientFactory _httpFactory;
    private readonly ILogger<MoyasarPaymentProvider> _logger;
    private readonly string _apiKey;
    private readonly string _webhookSecret;

    public MoyasarPaymentProvider(IConfiguration config, IHttpClientFactory httpFactory, ILogger<MoyasarPaymentProvider> logger)
    {
        _httpFactory = httpFactory;
        _logger = logger;
        _apiKey = (config["PAYMENTS_API_KEY"] ?? string.Empty).Trim();
        _webhookSecret = (config["PAYMENTS_WEBHOOK_SECRET"] ?? string.Empty).Trim();

        if (!Configured)
        {
            _logger.LogWarning(
                "payments(moyasar): selected but NOT configured — set PAYMENTS_API_KEY to enable. " +
                "Payment creation will return an error until then.");
        }
    }

    public string ProviderName => "moyasar";

    public bool Configured => _apiKey.Length > 0;

    public async Task<ProviderCreateResult> CreateAsync(ProviderCreateRequest req, CancellationToken ct = default)
    {
        if (!Configured)
            return ProviderCreateResult.Fail("Moyasar is not configured (set PAYMENTS_API_KEY).");

        var payload = new
        {
            amount = req.AmountMinor,            // halalas for SAR
            currency = req.Currency,
            description = req.Description,
            callback_url = req.CallbackUrl,
            metadata = new { reference = req.Reference },
        };

        try
        {
            using var http = _httpFactory.CreateClient("payments");
            using var request = new HttpRequestMessage(HttpMethod.Post, $"{ApiBase}/invoices")
            {
                Content = new StringContent(JsonSerializer.Serialize(payload), Encoding.UTF8, "application/json"),
            };
            // HTTP Basic auth: secret key as the username, empty password.
            var basic = Convert.ToBase64String(Encoding.UTF8.GetBytes(_apiKey + ":"));
            request.Headers.Authorization = new AuthenticationHeaderValue("Basic", basic);

            using var res = await http.SendAsync(request, ct);
            var body = await res.Content.ReadAsStringAsync(ct);
            if (!res.IsSuccessStatusCode)
            {
                _logger.LogWarning("payments(moyasar): create failed {Status}: {Body}", (int)res.StatusCode, body);
                return ProviderCreateResult.Fail($"Moyasar returned {(int)res.StatusCode}: {ExtractMessage(body)}");
            }

            using var doc = JsonDocument.Parse(body);
            var root = doc.RootElement;
            var id = root.TryGetProperty("id", out var idEl) ? idEl.GetString() : null;
            var url = root.TryGetProperty("url", out var urlEl) ? urlEl.GetString() : null;
            if (string.IsNullOrWhiteSpace(id))
                return ProviderCreateResult.Fail("Moyasar response had no invoice id.");

            _logger.LogInformation("payments(moyasar): created invoice {Id} for ref={Ref}", id, req.Reference);
            return ProviderCreateResult.Ok(id!, url);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "payments(moyasar): create threw.");
            return ProviderCreateResult.Fail(ex.Message);
        }
    }

    // Moyasar webhooks carry a `secret_token` you set on the webhook in the
    // dashboard. Authenticity = that token equals PAYMENTS_WEBHOOK_SECRET (compared
    // in constant time). A blank configured secret => reject (you MUST set it live).
    public bool VerifyWebhook(string rawBody, IHeaderDictionary headers)
    {
        if (_webhookSecret.Length == 0)
        {
            _logger.LogWarning("payments(moyasar): PAYMENTS_WEBHOOK_SECRET is not set — rejecting webhook.");
            return false;
        }
        try
        {
            using var doc = JsonDocument.Parse(rawBody);
            var token = doc.RootElement.TryGetProperty("secret_token", out var t) ? t.GetString() : null;
            if (string.IsNullOrEmpty(token)) return false;
            var a = Encoding.UTF8.GetBytes(token);
            var b = Encoding.UTF8.GetBytes(_webhookSecret);
            return a.Length == b.Length && System.Security.Cryptography.CryptographicOperations.FixedTimeEquals(a, b);
        }
        catch (JsonException)
        {
            return false;
        }
    }

    // Moyasar events look like { "type": "payment_paid"|"invoice_paid"|...,
    //   "secret_token": "...", "data": { "id": "...", "status": "...",
    //   "invoice_id": "inv_..." (on payment_* events) } }. We match on the INVOICE
    // id (what we stored as the provider payment id), falling back to data.id.
    public WebhookEvent? ParseWebhook(string rawBody)
    {
        try
        {
            using var doc = JsonDocument.Parse(rawBody);
            var root = doc.RootElement;
            if (!root.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object)
                return null;

            string? id = null;
            if (data.TryGetProperty("invoice_id", out var inv) && inv.ValueKind == JsonValueKind.String)
                id = inv.GetString();
            if (string.IsNullOrEmpty(id) && data.TryGetProperty("id", out var idEl))
                id = idEl.GetString();
            if (string.IsNullOrWhiteSpace(id)) return null;

            // Prefer data.status; otherwise infer from the event type.
            string? status = data.TryGetProperty("status", out var st) ? st.GetString() : null;
            if (string.IsNullOrWhiteSpace(status) && root.TryGetProperty("type", out var ty))
                status = ty.GetString();

            return new WebhookEvent(id!, Normalize(status));
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string Normalize(string? status) => (status ?? string.Empty).Trim().ToLowerInvariant() switch
    {
        "paid" or "payment_paid" or "invoice_paid" or "succeeded" or "captured" => "paid",
        "failed" or "payment_failed" or "voided" or "declined" => "failed",
        "refunded" or "payment_refunded" => "refunded",
        _ => "pending",
    };

    private static string ExtractMessage(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("message", out var m)) return m.GetString() ?? body;
        }
        catch (JsonException) { /* fall through */ }
        return body;
    }
}
