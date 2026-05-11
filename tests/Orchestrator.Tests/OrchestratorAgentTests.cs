using InteriorDesign.Orchestrator.Agents;
using InteriorDesign.Orchestrator.Services;
using InteriorDesign.Shared.Contracts;
using Microsoft.Extensions.Logging.Abstractions;

namespace InteriorDesign.Orchestrator.Tests;

public class OrchestratorAgentTests
{
    [Fact]
    public async Task Run_HappyPath_ReturnsImageAndNarrative()
    {
        var orch = Build(out var chat, out var search, out var image);

        var resp = await orch.RunAsync(new DesignRequest("modern bathroom with matte black taps"));

        Assert.NotNull(resp);
        Assert.False(string.IsNullOrWhiteSpace(resp.Narrative));
        Assert.Equal("A nice modern bathroom narrative.", resp.Narrative);
        Assert.NotEmpty(resp.Selections);
        Assert.NotNull(resp.GeneratedImageBase64);
        // Pipeline traces: plan -> retrieve -> compose -> render -> done
        Assert.Contains(resp.Trace, t => t.Step == "plan");
        Assert.Contains(resp.Trace, t => t.Step == "retrieve");
        Assert.Contains(resp.Trace, t => t.Step == "compose");
        Assert.Contains(resp.Trace, t => t.Step == "render");
        Assert.Contains(resp.Trace, t => t.Step == "done");
    }

    [Fact]
    public async Task Run_PreservesConversationId_AcrossTurns()
    {
        var orch = Build(out _, out _, out _);
        const string convo = "abc123";

        var resp = await orch.RunAsync(new DesignRequest("brief", ConversationId: convo));

        Assert.Equal(convo, resp.ConversationId);
    }

    [Fact]
    public async Task Run_ForwardsBrandFilterAndStyleHintsToSearchAndCompose()
    {
        var orch = Build(out var chat, out var search, out _);

        var brands = new[] { "Jaguar", "Parryware" };
        var styles = new[] { "luxury", "marble" };
        await orch.RunAsync(new DesignRequest("brief", PreferredBrands: brands, StyleHints: styles));

        Assert.Equal(brands, search.LastBrandFilter);
        // Compose user prompt must surface the style hints so they become part of the image prompt.
        Assert.Contains("luxury", chat.LastComposeUserPrompt);
        Assert.Contains("marble", chat.LastComposeUserPrompt);
        // Compose user prompt must surface the catalog vocabulary returned by search.
        Assert.Contains("Florentine Mixer", chat.LastComposeUserPrompt);
        Assert.Contains("matte black", chat.LastComposeUserPrompt);
    }

    [Fact]
    public async Task Run_ImageFailure_StillReturnsNarrativeAndSelections_AndTracesError()
    {
        var image = new FakeImageGen { Throw = new InvalidOperationException("rate limited") };
        var orch = new OrchestratorAgent(
            new FakeChat(), new FakeSearch(), image, new NullStore(), new NullPageImages(), NullLogger<OrchestratorAgent>.Instance);

        var resp = await orch.RunAsync(new DesignRequest("any brief"));

        Assert.NotNull(resp);
        Assert.False(string.IsNullOrWhiteSpace(resp.Narrative));
        Assert.NotEmpty(resp.Selections);
        Assert.Null(resp.GeneratedImageBase64);
        Assert.Null(resp.GeneratedImageUrl);
        Assert.Contains(resp.Trace, t => t.Step == "render-error" && t.Detail.Contains("rate limited"));
    }

    [Fact]
    public async Task Run_PlanFallsBackToOriginalPrompt_WhenChatReturnsBlank()
    {
        var chat = new FakeChat { PlanResponse = "   " };
        var orch = new OrchestratorAgent(
            chat, new FakeSearch(), new FakeImageGen(), new NullStore(), new NullPageImages(), NullLogger<OrchestratorAgent>.Instance);

        await orch.RunAsync(new DesignRequest("Original designer brief"));

        // The plan trace must carry the original brief when the chat agent returned nothing useful.
        var planTrace = Assert.Single(chat.PlanInvocations);
        Assert.Equal("Original designer brief", planTrace);
    }

    // ---- Test helpers --------------------------------------------------

    private static OrchestratorAgent Build(out FakeChat chat, out FakeSearch search, out FakeImageGen image)
    {
        chat = new FakeChat();
        search = new FakeSearch();
        image = new FakeImageGen();
        return new OrchestratorAgent(chat, search, image, new NullStore(), new NullPageImages(), NullLogger<OrchestratorAgent>.Instance);
    }

    /// <summary>
    /// Test stub: no embedded raster images on any page. Lets the orchestrator
    /// exercise its visual-grounding step with a clean "no refs found" path.
    /// </summary>
    private sealed class NullPageImages : ICatalogPageImageExtractor
    {
        public Task<CatalogPageImageExtractor.HeroResult> TryGetHeroAsync(string brand, string sourceFile, int pageNumber, CancellationToken ct = default)
            => Task.FromResult(CatalogPageImageExtractor.HeroResult.Failure(
                CatalogPageImageExtractor.HeroStatus.NoImagesOnPage,
                "test stub - always returns no-images"));

        public Task<CatalogPageImageExtractor.RenderResult> TryRenderPageAsync(string brand, string sourceFile, int pageNumber, int maxWidthPx, CancellationToken ct = default)
            => Task.FromResult(CatalogPageImageExtractor.RenderResult.Failure(
                CatalogPageImageExtractor.HeroStatus.PdfOpenFailed,
                "test stub - never actually renders"));
    }

    private sealed class FakeChat : IChatAgent
    {
        public string Name => "fake-chat";
        public string PlanResponse { get; set; } = "matte black bathroom fittings";
        public string ComposeResponse { get; set; } = "A nice modern bathroom narrative.\n---\nA crisp photoreal prompt.";
        public List<string> PlanInvocations { get; } = new();
        public string LastComposeUserPrompt { get; private set; } = string.Empty;

        public Task<string> RespondAsync(string s, string u, CancellationToken ct = default)
        {
            // The orchestrator's plan call uses a system prompt about a "search query for a bathroom-fittings catalog"
            // and the compose call uses a system prompt about a "senior interior-design copywriter".
            if (s.Contains("copywriter", StringComparison.OrdinalIgnoreCase))
            {
                LastComposeUserPrompt = u;
                return Task.FromResult(ComposeResponse);
            }

            PlanInvocations.Add(u);
            return Task.FromResult(PlanResponse);
        }

        public Task<string> RespondWithImagesAsync(string s, string u, IReadOnlyList<string> imageDataUrls, CancellationToken ct = default)
            => Task.FromResult(string.Empty);
    }

    private sealed class FakeSearch : ICatalogSearchAgent
    {
        public string Name => "fake-search";
        public IReadOnlyList<string>? LastBrandFilter { get; private set; }

        public Task<IReadOnlyList<CatalogItem>> FindAsync(string q, IReadOnlyList<string>? b, CancellationToken ct = default)
        {
            LastBrandFilter = b;
            return Task.FromResult<IReadOnlyList<CatalogItem>>(new[]
            {
                new CatalogItem("1", "Jaguar",    "tap",   "Florentine Mixer", "matte black, single-lever, deck-mounted", null, 0.9),
                new CatalogItem("2", "Parryware", "shower", "Rain Shower Pro",  "ceiling-mounted rain shower in chrome",  null, 0.85),
            });
        }
    }

    private sealed class FakeImageGen : IImageGenAgent
    {
        public string Name => "fake-image";
        public Exception? Throw { get; set; }
        public string? LastPrompt { get; private set; }

        public Task<byte[]> GenerateAsync(string p, CancellationToken ct = default)
        {
            LastPrompt = p;
            if (Throw is not null) throw Throw;
            return Task.FromResult(new byte[] { 1, 2, 3, 4 });
        }
    }

    private sealed class NullStore : GeneratedImageStore
    {
        public NullStore() : base(
            Microsoft.Extensions.Options.Options.Create(new Orchestrator.Options.AzureOptions
            {
                BlobAccountUrl = "https://placeholder.blob.core.windows.net",
                GeneratedContainer = "generated"
            }),
            new Azure.Identity.DefaultAzureCredential()) { }

        // Don't actually call blob storage in unit tests.
        public override Task<Uri> SaveAsync(byte[] png, string conversationId, CancellationToken ct = default)
            => Task.FromResult(new Uri($"https://placeholder.blob.core.windows.net/generated/{conversationId}.png"));
    }
}

