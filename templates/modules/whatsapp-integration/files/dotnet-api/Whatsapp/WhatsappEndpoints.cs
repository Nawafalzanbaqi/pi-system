// ===========================================================================
// whatsapp-integration — example HTTP endpoints for "__PROJECT_NAME__".
// ---------------------------------------------------------------------------
// Registered as an IStartupFilter by WhatsappHostingStartup. Implemented as
// terminal middleware (a path branch) so it is independent of endpoint-routing
// order and never collides with the base / bookings / auth-sso routes — the same
// approach auth-sso uses for /api/me.
//
// Routes (under the service's existing host, fronted by Caddy — no new routes):
//   GET  /api/whatsapp/status     active provider + whether it can actually send
//   POST /api/whatsapp/send       send a text or a template (uses IWhatsappSender)
//   GET  /api/whatsapp/webhook    Meta webhook VERIFY handshake (echoes challenge)
//   POST /api/whatsapp/webhook    inbound messages/status — X-Hub-Signature-256 verified
// ===========================================================================
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace PiSystem.Whatsapp;

public sealed class WhatsappEndpoints : IStartupFilter
{
    public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
    {
        // Map() strips the "/api/whatsapp" prefix; ctx.Request.Path is the remainder
        // (e.g. "/send", "/webhook"), which we dispatch on together with the method.
        app.Map("/api/whatsapp", branch => branch.Run(async ctx =>
        {
            var path = ctx.Request.Path.Value ?? string.Empty;
            var method = ctx.Request.Method;

            if (path is "/status" && HttpMethods.IsGet(method)) { await Status(ctx); return; }
            if (path is "/send" && HttpMethods.IsPost(method)) { await Send(ctx); return; }
            if (path is "/webhook" && HttpMethods.IsGet(method)) { await VerifyWebhook(ctx); return; }
            if (path is "/webhook" && HttpMethods.IsPost(method)) { await ReceiveWebhook(ctx); return; }

            ctx.Response.StatusCode = StatusCodes.Status404NotFound;
        }));

        next(app);
    };

    // --- GET /api/whatsapp/status --------------------------------------------
    private static async Task Status(HttpContext ctx)
    {
        var sender = ctx.RequestServices.GetRequiredService<IWhatsappSender>();
        await WriteJson(ctx, StatusCodes.Status200OK, new
        {
            provider = sender.ProviderName,
            configured = sender.Configured,
            note = sender.ProviderName == "mock"
                ? "Mock provider active — messages are logged, not delivered. Set WHATSAPP_PROVIDER=cloud_api with Meta credentials to send for real."
                : (sender.Configured
                    ? "Cloud API active and configured."
                    : "Cloud API selected but missing credentials — set WHATSAPP_PHONE_NUMBER_ID and WHATSAPP_ACCESS_TOKEN."),
        });
    }

    // --- POST /api/whatsapp/send ---------------------------------------------
    // Body: { "to": "9665...", "message": "hi" }                       -> text
    //   or: { "to": "9665...", "template": "appointment_reminder",
    //         "language": "ar", "parameters": ["Dr. X","Sun 10:00"] }  -> template
    private static async Task Send(HttpContext ctx)
    {
        var sender = ctx.RequestServices.GetRequiredService<IWhatsappSender>();

        SendRequest? req;
        try
        {
            req = await JsonSerializer.DeserializeAsync<SendRequest>(
                ctx.Request.Body,
                new JsonSerializerOptions(JsonSerializerDefaults.Web),
                ctx.RequestAborted);
        }
        catch (JsonException)
        {
            await WriteJson(ctx, StatusCodes.Status400BadRequest, new { error = "Invalid JSON body." });
            return;
        }

        if (req is null || string.IsNullOrWhiteSpace(req.To))
        {
            await WriteJson(ctx, StatusCodes.Status400BadRequest, new { error = "\"to\" (recipient phone, E.164) is required." });
            return;
        }

        WhatsappSendResult result;
        if (!string.IsNullOrWhiteSpace(req.Template))
        {
            result = await sender.SendTemplateAsync(
                req.To, req.Template!, string.IsNullOrWhiteSpace(req.Language) ? "en" : req.Language!,
                req.Parameters ?? Array.Empty<string>(), ctx.RequestAborted);
        }
        else if (!string.IsNullOrWhiteSpace(req.Message))
        {
            result = await sender.SendTextAsync(req.To, req.Message!, ctx.RequestAborted);
        }
        else
        {
            await WriteJson(ctx, StatusCodes.Status400BadRequest,
                new { error = "Provide either \"message\" (text) or \"template\" (+ optional language/parameters)." });
            return;
        }

        // 200 on success; 502 when the provider couldn't deliver (e.g. inert Cloud API).
        await WriteJson(ctx, result.Success ? StatusCodes.Status200OK : StatusCodes.Status502BadGateway, result);
    }

    // --- GET /api/whatsapp/webhook -------------------------------------------
    // Meta's subscription handshake: echo hub.challenge when hub.verify_token
    // matches WHATSAPP_VERIFY_TOKEN. See SETUP.md (this is a one-time registration).
    private static async Task VerifyWebhook(HttpContext ctx)
    {
        var config = ctx.RequestServices.GetRequiredService<IConfiguration>();
        var expected = (config["WHATSAPP_VERIFY_TOKEN"] ?? string.Empty).Trim();

        var q = ctx.Request.Query;
        var mode = q["hub.mode"].ToString();
        var token = q["hub.verify_token"].ToString();
        var challenge = q["hub.challenge"].ToString();

        if (mode == "subscribe" && expected.Length > 0 && FixedTimeEquals(token, expected))
        {
            ctx.Response.StatusCode = StatusCodes.Status200OK;
            ctx.Response.ContentType = "text/plain; charset=utf-8";
            await ctx.Response.WriteAsync(challenge, ctx.RequestAborted);
            return;
        }

        ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
    }

    // --- POST /api/whatsapp/webhook ------------------------------------------
    // Inbound messages / delivery-status events from Meta. The payload is verified
    // with HMAC-SHA256 over the RAW body using WHATSAPP_APP_SECRET (Meta's
    // X-Hub-Signature-256 header). With no app secret set (mock/dev), we accept but
    // log a warning, so the flow is still exercisable without Meta.
    private static async Task ReceiveWebhook(HttpContext ctx)
    {
        var config = ctx.RequestServices.GetRequiredService<IConfiguration>();
        var logger = ctx.RequestServices.GetRequiredService<ILoggerFactory>().CreateLogger("whatsapp.webhook");
        var appSecret = (config["WHATSAPP_APP_SECRET"] ?? string.Empty).Trim();

        // Read the raw body once (needed both for signature check and parsing).
        string raw;
        using (var reader = new StreamReader(ctx.Request.Body, Encoding.UTF8))
            raw = await reader.ReadToEndAsync(ctx.RequestAborted);

        if (appSecret.Length > 0)
        {
            var sigHeader = ctx.Request.Headers["X-Hub-Signature-256"].ToString();
            if (!VerifySignature(raw, appSecret, sigHeader))
            {
                logger.LogWarning("whatsapp(webhook): rejected — invalid X-Hub-Signature-256.");
                ctx.Response.StatusCode = StatusCodes.Status401Unauthorized;
                return;
            }
        }
        else
        {
            logger.LogWarning(
                "whatsapp(webhook): WHATSAPP_APP_SECRET is not set — accepting the payload WITHOUT signature " +
                "verification (development only; set it before going live).");
        }

        // We don't persist inbound events here (database: none). Log a short summary
        // and ACK 200 quickly so Meta does not retry. Hook your own handling in here.
        logger.LogInformation("whatsapp(webhook): received {Bytes} bytes.", Encoding.UTF8.GetByteCount(raw));
        ctx.Response.StatusCode = StatusCodes.Status200OK;
    }

    // ----------------------------------------------------------------------
    private static bool VerifySignature(string rawBody, string appSecret, string signatureHeader)
    {
        // Header format: "sha256=<hex>".
        const string prefix = "sha256=";
        if (string.IsNullOrEmpty(signatureHeader) || !signatureHeader.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            return false;

        var provided = signatureHeader[prefix.Length..].Trim();
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(appSecret));
        var computed = Convert.ToHexString(hmac.ComputeHash(Encoding.UTF8.GetBytes(rawBody))).ToLowerInvariant();
        return FixedTimeEquals(provided.ToLowerInvariant(), computed);
    }

    // Constant-time string compare (avoids leaking length/contents via timing).
    private static bool FixedTimeEquals(string a, string b)
    {
        var ba = Encoding.UTF8.GetBytes(a ?? string.Empty);
        var bb = Encoding.UTF8.GetBytes(b ?? string.Empty);
        return ba.Length == bb.Length && CryptographicOperations.FixedTimeEquals(ba, bb);
    }

    private static async Task WriteJson(HttpContext ctx, int status, object payload)
    {
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json; charset=utf-8";
        // Web defaults => camelCase, matching the JS provider's shape (success,
        // provider, messageId, error) and the rest of the API.
        await ctx.Response.WriteAsync(
            JsonSerializer.Serialize(payload, new JsonSerializerOptions(JsonSerializerDefaults.Web)), ctx.RequestAborted);
    }

    // Shape of the POST /api/whatsapp/send body.
    private sealed record SendRequest(
        string? To,
        string? Message,
        string? Template,
        string? Language,
        string[]? Parameters);
}
