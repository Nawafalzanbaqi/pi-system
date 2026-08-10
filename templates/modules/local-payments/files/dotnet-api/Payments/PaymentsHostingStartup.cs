// ===========================================================================
// local-payments — wiring for "__PROJECT_NAME__" (.NET).
// ---------------------------------------------------------------------------
// ADDITIVE, like auth-sso / whatsapp-integration: an [assembly: HostingStartup] the
// ASP.NET host runs at start-up when the service env sets
//
//     ASPNETCORE_HOSTINGSTARTUPASSEMBLIES=app
//
// (the compose fragment sets it). Because it is a HostingStartup and NOT a
// Program.cs edit, this composes cleanly with bookings (which owns Program.cs /
// app.csproj) and with auth-sso / whatsapp (other HostingStartups in the same "app"
// assembly — the host runs ALL of them). The Npgsql dependency is added by the
// sibling Directory.Build.targets (conditionally, so it never duplicates bookings').
//
// It registers the SWAPPABLE provider (chosen here, once, from PAYMENTS_PROVIDER),
// the repository, the startup schema migrator (as an IHostedService) and an
// IStartupFilter that adds the /api/payments/* endpoints. The mock provider is the
// default, so the full lifecycle is functional with no credentials.
// ===========================================================================
using System.Net.Http;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using PiSystem.LocalPayments;

[assembly: HostingStartup(typeof(PiSystem.LocalPayments.PaymentsHostingStartup))]

namespace PiSystem.LocalPayments;

public sealed class PaymentsHostingStartup : IHostingStartup
{
    public void Configure(IWebHostBuilder builder)
    {
        builder.ConfigureServices((context, services) =>
        {
            services.AddHttpClient();

            // Records payment intents/status in the project's own PostgreSQL.
            services.AddSingleton<PaymentsRepository>();

            // --- Pick the provider ONCE, from PAYMENTS_PROVIDER --------------
            // Blank or "mock" => the mock provider (default). "moyasar" => the real
            // Saudi gateway. Endpoints + repository depend only on IPaymentProvider.
            services.AddSingleton<IPaymentProvider>(sp =>
            {
                var config = sp.GetRequiredService<IConfiguration>();
                var provider = (config["PAYMENTS_PROVIDER"] ?? string.Empty).Trim().ToLowerInvariant();

                return provider switch
                {
                    "moyasar" => new MoyasarPaymentProvider(
                        config,
                        sp.GetRequiredService<IHttpClientFactory>(),
                        sp.GetRequiredService<ILogger<MoyasarPaymentProvider>>()),
                    // "", "mock", or anything unrecognised => the safe mock default.
                    _ => new MockPaymentProvider(
                        config,
                        sp.GetRequiredService<ILogger<MockPaymentProvider>>()),
                };
            });

            // Ensure the schema on startup (guarded; never blocks host start-up).
            services.AddHostedService<PaymentsMigrator>();

            // Add the /api/payments/* endpoints (terminal middleware — order-safe).
            services.AddSingleton<IStartupFilter, PaymentsEndpoints>();
        });
    }
}
