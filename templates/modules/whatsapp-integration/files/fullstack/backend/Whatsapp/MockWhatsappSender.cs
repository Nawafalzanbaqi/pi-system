// ===========================================================================
// pi-system module: whatsapp-integration — the MOCK provider (DEFAULT) for
// "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Active whenever WHATSAPP_PROVIDER is blank or "mock" (the default). It performs
// NO network call: it logs the message it WOULD have sent and returns success with
// a synthetic message id. This is what makes the entire WhatsApp flow runnable and
// testable right now with ZERO external accounts — exactly the swappable-provider
// promise. Flip WHATSAPP_PROVIDER=cloud_api (with Meta credentials) to send for
// real; nothing else in the app changes.
// ===========================================================================
using Microsoft.Extensions.Logging;

namespace PiSystem.Whatsapp;

public sealed class MockWhatsappSender : IWhatsappSender
{
    private readonly ILogger<MockWhatsappSender> _logger;

    public MockWhatsappSender(ILogger<MockWhatsappSender> logger) => _logger = logger;

    public string ProviderName => "mock";

    // The mock can always "send" — it has no external dependency.
    public bool Configured => true;

    public Task<WhatsappSendResult> SendTextAsync(string toPhone, string message, CancellationToken ct = default)
    {
        var id = NewId();
        _logger.LogInformation(
            "whatsapp(mock): TEXT -> {To} | id={Id} | body={Body}",
            Redact(toPhone), id, message);
        return Task.FromResult(WhatsappSendResult.Ok(ProviderName, id));
    }

    public Task<WhatsappSendResult> SendTemplateAsync(
        string toPhone, string templateName, string languageCode,
        IReadOnlyList<string> bodyParameters, CancellationToken ct = default)
    {
        var id = NewId();
        _logger.LogInformation(
            "whatsapp(mock): TEMPLATE '{Template}' [{Lang}] -> {To} | id={Id} | params=[{Params}]",
            templateName, languageCode, Redact(toPhone), id, string.Join(", ", bodyParameters));
        return Task.FromResult(WhatsappSendResult.Ok(ProviderName, id));
    }

    private static string NewId() => "wamid.MOCK-" + Guid.NewGuid().ToString("N")[..16].ToUpperInvariant();

    // Don't write full phone numbers to logs — keep the last 4 digits only.
    private static string Redact(string phone)
    {
        var p = (phone ?? string.Empty).Trim();
        return p.Length <= 4 ? "****" : new string('*', p.Length - 4) + p[^4..];
    }
}
