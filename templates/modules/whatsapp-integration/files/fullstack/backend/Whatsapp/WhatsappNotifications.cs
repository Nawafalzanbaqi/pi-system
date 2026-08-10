// ===========================================================================
// whatsapp-integration — higher-level notification helpers for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Convenience built ON TOP of IWhatsappSender. SendBookingConfirmationAsync is the
// COOPERATION point with the bookings module — but it takes plain arguments (no
// reference to any bookings type), so this file compiles whether or not bookings is
// composed in. It is therefore a real, ready-to-use helper AND a documented
// integration point, never a broken reference.
//
// To wire it into bookings (when both modules are present) resolve IWhatsappSender
// in the booking confirm flow and call it — e.g. in BookingsEndpoints, after a
// successful confirm:
//
//     var sender = ctx.RequestServices.GetRequiredService<IWhatsappSender>();
//     await sender.SendBookingConfirmationAsync(
//         booking.CustomerPhone, booking.Reference, serviceName, booking.StartsAt, locale);
//
// (See this module's README, "Cooperating with bookings".)
// ===========================================================================
namespace PiSystem.Whatsapp;

public static class WhatsappNotifications
{
    /// <summary>
    /// Send a bilingual booking confirmation. No-ops gracefully (returns a failed
    /// result, never throws) when the phone is blank, so callers can fire-and-forget.
    /// </summary>
    public static Task<WhatsappSendResult> SendBookingConfirmationAsync(
        this IWhatsappSender sender,
        string? customerPhone,
        string reference,
        string serviceName,
        DateTime startsAtUtc,
        string locale = "en",
        CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(customerPhone))
            return Task.FromResult(WhatsappSendResult.Fail(sender.ProviderName, "No recipient phone number."));

        var when = startsAtUtc.ToString("yyyy-MM-dd HH:mm 'UTC'");
        var body = locale == "ar"
            ? $"تم تأكيد حجزك ({reference}) لخدمة \"{serviceName}\" بتاريخ {when}. شكرًا لك."
            : $"Your booking ({reference}) for \"{serviceName}\" on {when} is confirmed. Thank you.";

        return sender.SendTextAsync(customerPhone!, body, ct);
    }
}
