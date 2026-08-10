// ===========================================================================
// pi-system module: local-payments — DTOs for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Plain data shapes exchanged over the /api/payments/* endpoints. Amounts are
// always in the currency's MINOR unit (e.g. halalas for SAR; 1000 = 10.00 SAR) to
// avoid floating-point money bugs end to end.
// ===========================================================================
namespace PiSystem.LocalPayments;

/// <summary>A payment as stored + reported to the app/UI. Never includes secrets.</summary>
public sealed record PaymentDto(
    long Id,
    string Reference,
    string Provider,
    string? ProviderPaymentId,
    long AmountMinor,
    string Currency,
    string Status,        // pending | paid | failed | refunded
    string Description,
    DateTime CreatedAt,
    DateTime? PaidAt);

/// <summary>Body of POST /api/payments. Amount is in the minor unit (halalas).</summary>
public sealed record CreatePaymentApiRequest(
    long? Amount,
    string? Currency,
    string? Description);

/// <summary>Outcome of recording a webhook against the database (drives idempotency).</summary>
public enum WebhookOutcome
{
    Applied,        // status moved forward (e.g. pending -> paid) — happened once
    AlreadyApplied, // duplicate/replayed webhook — no change (NO double-credit)
    Ignored,        // a non-advancing transition (e.g. failed after paid) — no change
    NotFound,       // no payment matches this provider payment id
    Unavailable,    // the payments database is not configured (not --db postgres)
}

public sealed record WebhookApplyResult(WebhookOutcome Outcome, PaymentDto? Payment);
