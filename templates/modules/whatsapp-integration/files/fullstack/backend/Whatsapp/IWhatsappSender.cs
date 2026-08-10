// ===========================================================================
// pi-system module: whatsapp-integration — the SWAPPABLE-PROVIDER interface for
// "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// The whole point of this module: ONE clean internal interface (IWhatsappSender)
// with TWO implementations behind it —
//   * MockWhatsappSender   (default) — logs/echoes the message and returns
//                          success, so the flow runs with NO external account;
//   * CloudApiWhatsappSender — the real WhatsApp Cloud API (Meta), fully coded,
//                          selected ONLY when WHATSAPP_PROVIDER=cloud_api AND the
//                          phone-number-id + access-token are present.
// The provider is chosen ONCE at startup by WhatsappHostingStartup from
// WHATSAPP_PROVIDER. Callers depend only on this interface — they never know (or
// care) which provider is live, so flipping mock -> live is a pure env change.
// ===========================================================================
namespace PiSystem.Whatsapp;

/// <summary>Sends WhatsApp messages. Implemented by a mock and the Cloud API.</summary>
public interface IWhatsappSender
{
    /// <summary>"mock" or "cloud_api" — the active provider (for /status + logs).</summary>
    string ProviderName { get; }

    /// <summary>
    /// True when the active provider has everything it needs to actually deliver.
    /// The mock is always "configured"; the Cloud API is configured only once its
    /// phone-number-id + access-token are set (otherwise it is INERT and returns a
    /// clear error instead of sending). Lets callers / the /status endpoint report
    /// readiness without exposing secrets.
    /// </summary>
    bool Configured { get; }

    /// <summary>Send a plain free-form text message (allowed inside the 24h
    /// customer-service window). <paramref name="toPhone"/> is an E.164 number
    /// WITHOUT a leading '+', e.g. "9665XXXXXXXX".</summary>
    Task<WhatsappSendResult> SendTextAsync(string toPhone, string message, CancellationToken ct = default);

    /// <summary>Send a pre-approved message TEMPLATE (the only way to message a
    /// user OUTSIDE the 24h window). <paramref name="bodyParameters"/> fill the
    /// template's {{1}}, {{2}}, … body placeholders in order.</summary>
    Task<WhatsappSendResult> SendTemplateAsync(
        string toPhone, string templateName, string languageCode,
        IReadOnlyList<string> bodyParameters, CancellationToken ct = default);
}

/// <summary>
/// The result of a send attempt. Never thrown — providers return this so callers
/// (and the example endpoint) can react without try/catch around every call.
/// </summary>
public sealed record WhatsappSendResult(
    bool Success,
    string Provider,
    string? MessageId,
    string? Error)
{
    public static WhatsappSendResult Ok(string provider, string? messageId) =>
        new(true, provider, messageId, null);

    public static WhatsappSendResult Fail(string provider, string error) =>
        new(false, provider, null, error);
}
