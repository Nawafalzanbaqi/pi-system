// ===========================================================================
// pi-system module: local-payments — the SWAPPABLE-PROVIDER interface for
// "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// The core of this module: ONE clean internal interface (IPaymentProvider) with
// TWO implementations behind it —
//   * MockPaymentProvider    (default) — simulates the WHOLE lifecycle locally
//                            (create -> pay -> signed webhook -> mark paid), so the
//                            flow is testable now with NO merchant account;
//   * MoyasarPaymentProvider — the real Saudi gateway (mada / Apple Pay / cards),
//                            fully coded, selected ONLY when PAYMENTS_PROVIDER=moyasar
//                            AND the API key is present.
// The provider is chosen ONCE at startup by PaymentsHostingStartup from
// PAYMENTS_PROVIDER. The endpoints + repository depend only on this interface, so
// flipping mock -> live is a pure env change.
//
// Webhook verification is part of the contract (VerifyWebhook) and is
// provider-specific: the mock verifies an HMAC-SHA256 signature header; Moyasar
// compares the secret_token carried in the payload. Either way the webhook is
// authenticated BEFORE its status is recorded.
// ===========================================================================
using Microsoft.AspNetCore.Http;

namespace PiSystem.LocalPayments;

public interface IPaymentProvider
{
    /// <summary>"mock" or "moyasar" — the active provider (for /_status + logs).</summary>
    string ProviderName { get; }

    /// <summary>
    /// True when the provider can actually take payments. The mock is always
    /// configured; Moyasar is configured only once its API key is set (otherwise it
    /// is INERT — create returns an error instead of calling out).
    /// </summary>
    bool Configured { get; }

    /// <summary>Create a payment at the provider for an already-persisted intent.
    /// Returns the provider's id + the URL to send the payer to (null for the mock,
    /// which is simulated in-app).</summary>
    Task<ProviderCreateResult> CreateAsync(ProviderCreateRequest req, CancellationToken ct = default);

    /// <summary>Authenticate an incoming webhook (signature / secret) BEFORE it is
    /// trusted. Constant-time. Returns false on any mismatch.</summary>
    bool VerifyWebhook(string rawBody, IHeaderDictionary headers);

    /// <summary>Parse a VERIFIED webhook body into a normalized event (the provider
    /// payment id this event concerns + a normalized status). Null if unparseable.</summary>
    WebhookEvent? ParseWebhook(string rawBody);
}

/// <summary>What the endpoint asks a provider to create (amount in minor units).</summary>
public sealed record ProviderCreateRequest(
    string Reference,
    long AmountMinor,
    string Currency,
    string Description,
    string CallbackUrl);

/// <summary>What a provider returns from CreateAsync.</summary>
public sealed record ProviderCreateResult(
    bool Success,
    string? ProviderPaymentId,
    string? RedirectUrl,
    string? Error)
{
    public static ProviderCreateResult Ok(string providerPaymentId, string? redirectUrl) =>
        new(true, providerPaymentId, redirectUrl, null);

    public static ProviderCreateResult Fail(string error) =>
        new(false, null, null, error);
}

/// <summary>A normalized webhook event: which provider payment, and its new status.</summary>
/// <remarks>Status is normalized to one of pending | paid | failed | refunded.</remarks>
public sealed record WebhookEvent(string ProviderPaymentId, string Status);
