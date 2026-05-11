using Azure.Core;
using Azure.Identity;
using InteriorDesign.Orchestrator.Agents;
using InteriorDesign.Orchestrator.Agents.Foundry;
using InteriorDesign.Orchestrator.Endpoints;
using InteriorDesign.Orchestrator.Foundry;
using InteriorDesign.Orchestrator.Options;
using InteriorDesign.Orchestrator.Services;
using Microsoft.Extensions.Options;

var builder = WebApplication.CreateBuilder(args);

// ---- Configuration & shared dependencies ----------------------------------
builder.Services.Configure<AzureOptions>(builder.Configuration.GetSection(AzureOptions.SectionName));

// Single TokenCredential reused by every Azure SDK + HttpClient bearer flow.
builder.Services.AddSingleton<TokenCredential>(_ => new DefaultAzureCredential(includeInteractiveCredentials: false));

// HttpClient + Foundry Responses client (no Content Understanding - replaced
// by Document Intelligence Layout extraction at deploy time, see deploy.ps1 Phase 5b).
builder.Services.AddHttpClient();
builder.Services.AddSingleton<FoundryResponsesClient>(sp =>
{
    var o = sp.GetRequiredService<IOptions<AzureOptions>>().Value;
    if (string.IsNullOrWhiteSpace(o.FoundryProjectEndpoint))
        throw new InvalidOperationException("Azure:FoundryProjectEndpoint is required (services.ai.azure.com NEW Foundry endpoint).");
    var http = sp.GetRequiredService<IHttpClientFactory>().CreateClient(nameof(FoundryResponsesClient));
    http.Timeout = TimeSpan.FromMinutes(2);
    return new FoundryResponsesClient(http, sp.GetRequiredService<TokenCredential>(), o.FoundryProjectEndpoint);
});

// Catalog search service (queries the brand-specific AI Search indexes)
builder.Services.AddSingleton(sp => CatalogSearchService.Create(
    sp.GetRequiredService<IOptions<AzureOptions>>(),
    sp.GetRequiredService<TokenCredential>()));

// Pulls the largest embedded raster image off a specific brand-catalog page
// for vision-grounded image generation (see OrchestratorAgent step 2.5).
builder.Services.AddSingleton<CatalogPageImageExtractor>();
builder.Services.AddSingleton<ICatalogPageImageExtractor>(sp => sp.GetRequiredService<CatalogPageImageExtractor>());

builder.Services.AddSingleton<GeneratedImageStore>();

// ---- Foundry-ONLY agent wiring (no LocalAgents fallback) -------------------
builder.Services.AddSingleton<IChatAgent>(sp =>
{
    var o = sp.GetRequiredService<IOptions<AzureOptions>>().Value;
    return new FoundryChatAgent(sp.GetRequiredService<FoundryResponsesClient>(), o.Agents.ChatAgent);
});

builder.Services.AddSingleton<ICatalogSearchAgent>(sp =>
{
    var o = sp.GetRequiredService<IOptions<AzureOptions>>().Value;
    return new FoundryCatalogSearchAgent(sp.GetRequiredService<FoundryResponsesClient>(), sp.GetRequiredService<CatalogSearchService>(), o.Agents.CatalogSearchAgent);
});

builder.Services.AddSingleton<IImageGenAgent>(sp =>
{
    var o = sp.GetRequiredService<IOptions<AzureOptions>>().Value;
    return new FoundryImageGenAgent(
        sp.GetRequiredService<FoundryResponsesClient>(),
        o.Agents.ImageGenAgent,
        sp.GetRequiredService<IOptions<AzureOptions>>(),
        sp.GetRequiredService<TokenCredential>());
});

builder.Services.AddSingleton<OrchestratorAgent>();

// ---- Cross-cutting --------------------------------------------------------
builder.Services.AddCors(p => p.AddDefaultPolicy(b =>
    b.AllowAnyHeader().AllowAnyMethod().AllowAnyOrigin()));
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddApplicationInsightsTelemetry();

var app = builder.Build();

app.UseCors();
app.MapDesignEndpoints();
app.MapCatalogPageEndpoint();
app.MapGet("/", () => Results.Ok(new { service = "InteriorDesign.Orchestrator", version = "0.2.0", agents = "foundry-only" }));

app.Run();

public partial class Program { }

