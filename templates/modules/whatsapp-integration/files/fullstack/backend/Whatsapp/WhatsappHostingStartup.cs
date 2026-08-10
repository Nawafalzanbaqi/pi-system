// ===========================================================================
// whatsapp-integration — wiring for "__PROJECT_NAME__" (.NET).
// ---------------------------------------------------------------------------
// ADDITIVE, like auth-sso: this is an [assembly: HostingStartup] that the ASP.NET
// host runs at start-up when the service env sets
//
//     ASPNETCORE_HOSTINGSTARTUPASSEMBLIES=app
//
// (the compose fragment sets it). Because it is a HostingStartup and NOT a
// Program.cs edit, whatsapp-integration composes cleanly with the modules that DO
// own Program.cs / app.csproj (bookings) and with auth-sso (another HostingStartup
// in the same "app" assembly — the host runs ALL of them). It needs no NuGet
// packages, so it adds no Directory.Build.props/.targets either.
//
// It registers the SWAPPABLE provider (chosen here, once, from WHATSAPP_PROVIDER)
// and an IStartupFilter that adds the example /api/whatsapp/* endpoints. The mock
// provider is the default, so this is fully functional with no credentials.
// ===========================================================================
using System.Net.Http;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using PiSystem.Whatsapp;

[assembly: HostingStartup(typeof(PiSystem.Whatsapp.WhatsappHostingStartup))]

namespace PiSystem.Whatsapp;

public sealed class WhatsappHostingStartup : IHostingStartup
{
    public void Configure(IWebHostBuilder builder)
    {
        builder.ConfigureServices((context, services) =>
        {
            // HttpClient (used by the Cloud API provider; harmless for the mock).
            services.AddHttpClient();

            // --- Pick the provider ONCE, from WHATSAPP_PROVIDER --------------
            // Blank or "mock" => the mock sender (default). "cloud_api" => the real
            // WhatsApp Cloud API provider. Callers depend only on IWhatsappSender,
            // so this is the single place the choice is made.
            services.AddSingleton<IWhatsappSender>(sp =>
            {
                var config = sp.GetRequiredService<IConfiguration>();
                var provider = (config["WHATSAPP_PROVIDER"] ?? string.Empty).Trim().ToLowerInvariant();

                return provider switch
                {
                    "cloud_api" or "cloudapi" or "cloud" => new CloudApiWhatsappSender(
                        config,
                        sp.GetRequiredService<IHttpClientFactory>(),
                        sp.GetRequiredService<ILogger<CloudApiWhatsappSender>>()),
                    // "", "mock", or anything unrecognised => the safe mock default.
                    _ => new MockWhatsappSender(sp.GetRequiredService<ILogger<MockWhatsappSender>>()),
                };
            });

            // Add the example endpoints (terminal middleware — routing-order safe).
            services.AddSingleton<IStartupFilter, WhatsappEndpoints>();
        });
    }
}
