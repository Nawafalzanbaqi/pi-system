// ===========================================================================
// pi-system module: whatsapp-integration — the REAL provider for "__PROJECT_NAME__":
// the WhatsApp Cloud API (Meta Graph API).
// ---------------------------------------------------------------------------
// Fully implemented against Meta's documented Cloud API send-message endpoint:
//
//   POST https://graph.facebook.com/<version>/<phone-number-id>/messages
//   Authorization: Bearer <access-token>
//   { "messaging_product": "whatsapp", "to": "...", "type": "text|template", ... }
//
// Selected ONLY when WHATSAPP_PROVIDER=cloud_api. It stays INERT until its
// credentials are present: with a blank phone-number-id or access-token it does NOT
// call out — Configured is false and every send returns a clear error (never an
// exception). So the real provider is "fully coded but dormant until env is set",
// which is exactly the deferred-credentials design. No external SDK — built-in
// HttpClient + System.Text.Json only (zero new dependencies, ARM64-safe).
// ===========================================================================
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace PiSystem.Whatsapp;

public sealed class CloudApiWhatsappSender : IWhatsappSender
{
    // Pinned default Graph API version (overridable via WHATSAPP_API_VERSION).
    private const string DefaultApiVersion = "v21.0";

    private readonly IHttpClientFactory _httpFactory;
    private readonly ILogger<CloudApiWhatsappSender> _logger;
    private readonly string _phoneNumberId;
    private readonly string _accessToken;
    private readonly string _apiVersion;

    public CloudApiWhatsappSender(IConfiguration config, IHttpClientFactory httpFactory, ILogger<CloudApiWhatsappSender> logger)
    {
        _httpFactory = httpFactory;
        _logger = logger;
        _phoneNumberId = (config["WHATSAPP_PHONE_NUMBER_ID"] ?? string.Empty).Trim();
        _accessToken = (config["WHATSAPP_ACCESS_TOKEN"] ?? string.Empty).Trim();
        var v = (config["WHATSAPP_API_VERSION"] ?? string.Empty).Trim();
        _apiVersion = string.IsNullOrEmpty(v) ? DefaultApiVersion : v;

        if (!Configured)
        {
            _logger.LogWarning(
                "whatsapp(cloud_api): selected but NOT configured — set WHATSAPP_PHONE_NUMBER_ID " +
                "and WHATSAPP_ACCESS_TOKEN to enable sending. Sends will return an error until then.");
        }
    }

    public string ProviderName => "cloud_api";

    public bool Configured => _phoneNumberId.Length > 0 && _accessToken.Length > 0;

    public Task<WhatsappSendResult> SendTextAsync(string toPhone, string message, CancellationToken ct = default)
    {
        var payload = new
        {
            messaging_product = "whatsapp",
            recipient_type = "individual",
            to = NormalizePhone(toPhone),
            type = "text",
            text = new { preview_url = false, body = message },
        };
        return SendAsync(payload, ct);
    }

    public Task<WhatsappSendResult> SendTemplateAsync(
        string toPhone, string templateName, string languageCode,
        IReadOnlyList<string> bodyParameters, CancellationToken ct = default)
    {
        // Build the optional body component only when there are parameters to fill.
        object template = bodyParameters is { Count: > 0 }
            ? new
            {
                name = templateName,
                language = new { code = languageCode },
                components = new object[]
                {
                    new
                    {
                        type = "body",
                        parameters = bodyParameters.Select(p => new { type = "text", text = p }).ToArray(),
                    },
                },
            }
            : new
            {
                name = templateName,
                language = new { code = languageCode },
            };

        var payload = new
        {
            messaging_product = "whatsapp",
            recipient_type = "individual",
            to = NormalizePhone(toPhone),
            type = "template",
            template,
        };
        return SendAsync(payload, ct);
    }

    private async Task<WhatsappSendResult> SendAsync(object payload, CancellationToken ct)
    {
        if (!Configured)
        {
            return WhatsappSendResult.Fail(ProviderName,
                "WhatsApp Cloud API is not configured (set WHATSAPP_PHONE_NUMBER_ID and WHATSAPP_ACCESS_TOKEN).");
        }

        var url = $"https://graph.facebook.com/{_apiVersion}/{_phoneNumberId}/messages";
        var json = JsonSerializer.Serialize(payload);

        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, url)
            {
                Content = new StringContent(json, Encoding.UTF8, "application/json"),
            };
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _accessToken);

            var http = _httpFactory.CreateClient("whatsapp");
            using var res = await http.SendAsync(req, ct);
            var body = await res.Content.ReadAsStringAsync(ct);

            if (!res.IsSuccessStatusCode)
            {
                _logger.LogWarning("whatsapp(cloud_api): send failed {Status}: {Body}", (int)res.StatusCode, body);
                return WhatsappSendResult.Fail(ProviderName, $"Cloud API returned {(int)res.StatusCode}: {ExtractError(body)}");
            }

            // Response shape: { "messages": [ { "id": "wamid...." } ], ... }
            var messageId = ExtractMessageId(body);
            _logger.LogInformation("whatsapp(cloud_api): sent id={Id}", messageId);
            return WhatsappSendResult.Ok(ProviderName, messageId);
        }
        catch (Exception ex)
        {
            // Network/transport failure — never throw into the caller.
            _logger.LogWarning(ex, "whatsapp(cloud_api): send threw.");
            return WhatsappSendResult.Fail(ProviderName, ex.Message);
        }
    }

    // E.164 without a leading '+': the Cloud API wants just the digits.
    private static string NormalizePhone(string phone)
    {
        var p = (phone ?? string.Empty).Trim();
        return p.StartsWith('+') ? p[1..] : p;
    }

    private static string? ExtractMessageId(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("messages", out var messages) &&
                messages.ValueKind == JsonValueKind.Array &&
                messages.GetArrayLength() > 0 &&
                messages[0].TryGetProperty("id", out var id))
            {
                return id.GetString();
            }
        }
        catch (JsonException) { /* fall through */ }
        return null;
    }

    private static string ExtractError(string body)
    {
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (doc.RootElement.TryGetProperty("error", out var err) &&
                err.TryGetProperty("message", out var msg))
            {
                return msg.GetString() ?? body;
            }
        }
        catch (JsonException) { /* fall through */ }
        return body;
    }
}
