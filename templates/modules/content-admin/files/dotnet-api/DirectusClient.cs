// content-admin (Directus) — minimal, OPTIONAL .NET content client for "__PROJECT_NAME__".
// =============================================================================
// Calls the headless CMS (Directus) over the INTERNAL Docker network. The CMS is
// reached by service name — the generator stamps the address in below; override
// it with the DIRECTUS_URL environment variable if needed.
//
// This helper uses the built-in System.Net.Http.HttpClient + System.Text.Json so
// it compiles with ZERO extra packages and never breaks the build. It is a
// starting point — delete it if you do not call the CMS from .NET.
//
// SUGGESTED UPGRADE — RestSharp: for a richer, fluent client (typed requests,
// query/param builders, auth handlers) install it and swap the calls below:
//     dotnet add package RestSharp
//     var client = new RestSharp.RestClient("http://__PROJECT_NAME__-cms:8055");
//     var req = new RestSharp.RestRequest("/items/pages")
//         .AddQueryParameter("filter[status][_eq]", "published");
//     var pages = await client.GetAsync<DirectusList<Page>>(req);
// See templates/modules/content-admin/README.md for the full .NET guidance.
//
// In a real app, register HttpClient via IHttpClientFactory rather than `new`:
//     builder.Services.AddHttpClient<DirectusClient>();
// =============================================================================
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ContentAdmin;

/// <summary>Read-only client for the Directus REST API on the internal network.</summary>
public sealed class DirectusClient
{
    private readonly HttpClient _http;
    private readonly string _baseUrl;
    private readonly string? _token;

    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNameCaseInsensitive = true,
    };

    public DirectusClient(HttpClient? http = null)
    {
        _baseUrl = (Environment.GetEnvironmentVariable("DIRECTUS_URL")
                    ?? "http://__PROJECT_NAME__-cms:8055").TrimEnd('/');
        // Optional static access token. If your collections grant read access to
        // the Public role in /admin, leave it unset and no auth is sent.
        _token = Environment.GetEnvironmentVariable("DIRECTUS_TOKEN");
        _http = http ?? new HttpClient();
    }

    // Directus wraps every payload in { "data": ... }.
    private sealed class Envelope<T>
    {
        [JsonPropertyName("data")] public T? Data { get; set; }
    }

    private HttpRequestMessage BuildRequest(string pathAndQuery)
    {
        var req = new HttpRequestMessage(HttpMethod.Get, _baseUrl + pathAndQuery);
        if (!string.IsNullOrWhiteSpace(_token))
            req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _token);
        return req;
    }

    /// <summary>GET /items/{collection} — returns a list (empty on any failure).</summary>
    public async Task<IReadOnlyList<T>> GetItemsAsync<T>(
        string collection, string? query = null, CancellationToken ct = default)
    {
        try
        {
            using var res = await _http.SendAsync(BuildRequest($"/items/{collection}{query}"), ct);
            if (!res.IsSuccessStatusCode) return Array.Empty<T>();
            var env = await res.Content.ReadFromJsonAsync<Envelope<List<T>>>(JsonOpts, ct);
            return env?.Data ?? new List<T>();
        }
        catch
        {
            // The CMS may still be booting, or the collection may not exist yet —
            // degrade gracefully rather than throwing into the request pipeline.
            return Array.Empty<T>();
        }
    }

    /// <summary>GET /items/{collection} for a "singleton" collection (e.g. settings).</summary>
    public async Task<T?> GetSingletonAsync<T>(
        string collection, string? query = null, CancellationToken ct = default)
    {
        try
        {
            using var res = await _http.SendAsync(BuildRequest($"/items/{collection}{query}"), ct);
            if (!res.IsSuccessStatusCode) return default;
            var env = await res.Content.ReadFromJsonAsync<Envelope<T>>(JsonOpts, ct);
            return env is null ? default : env.Data;
        }
        catch
        {
            return default;
        }
    }

    /// <summary>Convenience: published rows of a collection (assumes a `status` field).</summary>
    public Task<IReadOnlyList<T>> GetPublishedAsync<T>(string collection, CancellationToken ct = default)
        => GetItemsAsync<T>(collection, "?filter[status][_eq]=published&fields=*", ct);
}
