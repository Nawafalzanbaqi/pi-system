// ===========================================================================
// pi-system module: bookings — DTOs + result types for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Plain records, serialized by ASP.NET Core's default (web) JSON options, which
// emit camelCase — so ServiceDto.NameEn becomes "nameEn" on the wire, matching
// the frontend client (lib/bookings.js). No external packages.
// ===========================================================================
namespace Bookings;

/// <summary>A bookable service / resource (bilingual names).</summary>
public sealed record ServiceDto(
    long Id,
    string Slug,
    string NameEn,
    string NameAr,
    string DescriptionEn,
    string DescriptionAr,
    int DurationMinutes);

/// <summary>An available time slot for a service (with remaining capacity).</summary>
public sealed record SlotDto(
    long Id,
    long ServiceId,
    DateTime StartsAt,
    DateTime EndsAt,
    int Capacity,
    int Remaining);

/// <summary>A booking and its lifecycle status.</summary>
public sealed record BookingDto(
    long Id,
    string Reference,
    long SlotId,
    long ServiceId,
    string CustomerName,
    string CustomerEmail,
    string CustomerPhone,
    string Notes,
    string Status,
    DateTime StartsAt,
    DateTime EndsAt,
    DateTime CreatedAt);

/// <summary>
/// Request body for creating a booking. Only the slot + customer fields are
/// needed — the service is derived from the slot server-side.
/// </summary>
public sealed class CreateBookingRequest
{
    public long SlotId { get; set; }
    public string? CustomerName { get; set; }
    public string? CustomerEmail { get; set; }
    public string? CustomerPhone { get; set; }
    public string? Notes { get; set; }
}

/// <summary>Outcome of a create attempt (mapped to HTTP codes by the endpoints).</summary>
public enum CreateOutcome
{
    Created,
    ValidationFailed,
    SlotNotFound,
    SlotUnavailable,   // inactive or in the past
    SlotFull,          // capacity reached — a double-booking was prevented
    Unavailable,       // bookings DB not configured / unreachable
}

/// <summary>Outcome of a confirm / cancel attempt.</summary>
public enum StatusChangeOutcome
{
    Updated,
    NotFound,
    InvalidTransition,
    Unavailable,
}

public readonly record struct CreateResult(CreateOutcome Outcome, BookingDto? Booking, string? Error);
public readonly record struct StatusResult(StatusChangeOutcome Outcome, BookingDto? Booking, string? Error);
