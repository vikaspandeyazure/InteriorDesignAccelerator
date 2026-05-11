using InteriorDesign.Web.Ui.Components;
using InteriorDesign.Web.Ui.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorComponents()
    .AddInteractiveServerComponents();

// Typed HttpClient pointing at the Orchestrator API (set in appsettings or via env var
// Orchestrator__BaseUrl when running in App Service).
//
// NOTE: We deliberately do NOT add the standard resilience handler here.
// The orchestrator pipeline (AI Search + Content Understanding + MAI image gen)
// routinely takes 20-40s and can spike past a minute. The default standard
// resilience pipeline (10s/attempt, 30s total) was producing the
// "operation didn't complete within the allowed timeout of '00:00:30'" error.
// A simple long HttpClient.Timeout is the right primitive for a long-running
// generative call - retrying a 40s LLM/image call is almost always wrong.
builder.Services.AddHttpClient<DesignApiClient>((sp, http) =>
{
    var cfg = sp.GetRequiredService<IConfiguration>();
    var baseUrl = cfg["Orchestrator:BaseUrl"]
        ?? throw new InvalidOperationException("Orchestrator:BaseUrl is not configured.");
    http.BaseAddress = new Uri(baseUrl);
    http.Timeout = TimeSpan.FromMinutes(5);

    var key = cfg["Orchestrator:ApimSubscriptionKey"];
    if (!string.IsNullOrWhiteSpace(key))
        http.DefaultRequestHeaders.Add("Ocp-Apim-Subscription-Key", key);
});

var app = builder.Build();

// Surface clear startup diagnostics in the App Service log stream so we can
// tell from /api/logs/docker whether the worker actually started.
app.Logger.LogInformation(
    "Web.Ui starting. Env={Env} OrchestratorBaseUrl={Url}",
    app.Environment.EnvironmentName,
    builder.Configuration["Orchestrator:BaseUrl"] ?? "(not set)");

if (!app.Environment.IsDevelopment())
    app.UseExceptionHandler("/Error", createScopeForErrors: true);

app.UseStaticFiles();
app.UseAntiforgery();

app.MapRazorComponents<App>()
    .AddInteractiveServerRenderMode();

// ---- Catalog page image proxy ---------------------------------------------
// The browser cannot reach the orchestrator's /api/catalog/page* endpoints
// directly:
//   * In Azure, the orchestrator sits behind APIM and requires the
//     Ocp-Apim-Subscription-Key header. <img src=...> requests from the
//     browser don't carry that header so APIM returns 401.
//   * Locally, the configured Orchestrator:BaseUrl may not match the
//     orchestrator's actual listening port.
// We therefore proxy these requests through Web.Ui's own origin, using the
// already-authenticated typed HttpClient on DesignApiClient. The browser only
// ever talks to Web.Ui (same origin as the Blazor app); Web.Ui talks to the
// orchestrator with the subscription key attached.
static async Task ProxyAsync(string relativePath, DesignApiClient api, HttpContext http, CancellationToken ct)
{
    using var upstream = await api.GetRawAsync(relativePath, ct);
    http.Response.StatusCode = (int)upstream.StatusCode;
    // Forward content-type and cache headers verbatim so img caching still works.
    if (upstream.Content.Headers.ContentType is { } ct1)
        http.Response.ContentType = ct1.ToString();
    if (upstream.Headers.CacheControl is { } cc)
        http.Response.Headers.CacheControl = cc.ToString();
    if (!upstream.IsSuccessStatusCode)
    {
        var body = await upstream.Content.ReadAsStringAsync(ct);
        await http.Response.WriteAsync(body, ct);
        return;
    }
    await using var s = await upstream.Content.ReadAsStreamAsync(ct);
    await s.CopyToAsync(http.Response.Body, ct);
}

app.MapGet("/ui/catalog/page-rendered", (string brand, string file, int page, int? width,
    DesignApiClient api, HttpContext http, CancellationToken ct) =>
{
    var qs = $"/api/catalog/page-rendered?brand={Uri.EscapeDataString(brand)}&file={Uri.EscapeDataString(file)}&page={page}";
    if (width is int w) qs += $"&width={w}";
    return ProxyAsync(qs, api, http, ct);
});

app.MapGet("/ui/catalog/page-image", (string brand, string file, int page,
    DesignApiClient api, HttpContext http, CancellationToken ct) =>
{
    var qs = $"/api/catalog/page-image?brand={Uri.EscapeDataString(brand)}&file={Uri.EscapeDataString(file)}&page={page}";
    return ProxyAsync(qs, api, http, ct);
});

app.MapGet("/ui/catalog/page", (string brand, string file, int? page,
    DesignApiClient api, HttpContext http, CancellationToken ct) =>
{
    var qs = $"/api/catalog/page?brand={Uri.EscapeDataString(brand)}&file={Uri.EscapeDataString(file)}";
    if (page is int p) qs += $"&page={p}";
    return ProxyAsync(qs, api, http, ct);
});

app.Run();

