using System.Diagnostics;
using InteriorDesign.Shared.Contracts;
using Microsoft.Extensions.Logging;

namespace InteriorDesign.Orchestrator.Agents;

/// <summary>
/// Multi-agent orchestrator implemented as an explicit pipeline:
///
///   1. Plan        - ChatAgent rewrites the designer prompt into a structured search query.
///   2. Retrieve    - CatalogSearchAgent pulls grounded products from AI Search (Foundry KB).
///                    Each product carries its own pre-extracted description (Document
///                    Intelligence Layout output, indexed during deploy.ps1 Phase 5b).
///   3. Compose     - ChatAgent writes a single image-generation prompt + a designer narrative,
///                    grounded in the brand vocabulary returned by step 2.
///   4. Render      - ImageGenAgent calls MAI-Image to produce the final 1024x1024 PNG.
///
/// This is the "Microsoft Agent Framework" surface: a deterministic group-chat-style
/// flow that combines Semantic Kernel reasoning steps with AutoGen-style turn handoff
/// while keeping each step independently testable (see tests/Orchestrator.Tests).
/// </summary>
public sealed class OrchestratorAgent
{
    private readonly IChatAgent _chat;
    private readonly ICatalogSearchAgent _search;
    private readonly IImageGenAgent _imageGen;
    private readonly Services.GeneratedImageStore _store;
    private readonly Services.ICatalogPageImageExtractor _pageImages;
    private readonly ILogger<OrchestratorAgent> _log;

    public OrchestratorAgent(
        IChatAgent chat,
        ICatalogSearchAgent search,
        IImageGenAgent imageGen,
        Services.GeneratedImageStore store,
        Services.ICatalogPageImageExtractor pageImages,
        ILogger<OrchestratorAgent> log)
    {
        _chat = chat;
        _search = search;
        _imageGen = imageGen;
        _store = store;
        _pageImages = pageImages;
        _log = log;
    }

    public Task<DesignResponse> RunAsync(DesignRequest req, CancellationToken ct = default)
        => RunAsync(req, onTrace: null, ct: ct);

    /// <summary>
    /// Streaming variant: invokes <paramref name="onTrace"/> with each agent step
    /// as soon as it completes (plan / retrieve / compose / render / done) so the
    /// caller can surface live progress in the UI (Foundry-Playground-style trace).
    /// The returned <see cref="DesignResponse"/> still carries the full trace list
    /// so a non-streaming consumer behaves identically to <see cref="RunAsync(DesignRequest, CancellationToken)"/>.
    /// </summary>
    public async Task<DesignResponse> RunAsync(
        DesignRequest req,
        Func<AgentTrace, Task>? onTrace,
        CancellationToken ct = default)
    {
        var trace = new List<AgentTrace>();
        var conversationId = req.ConversationId ?? Guid.NewGuid().ToString("n");
        var sw = Stopwatch.StartNew();

        async Task EmitAsync(AgentTrace t)
        {
            trace.Add(t);
            if (onTrace is not null)
            {
                try { await onTrace(t); }
                catch (Exception cbEx) { _log.LogWarning(cbEx, "onTrace callback threw - swallowing to keep pipeline alive"); }
            }
        }

        // 0) Started
        await EmitAsync(new AgentTrace("orchestrator", "started",
            $"brief='{Truncate(req.Prompt, 120)}', brands=[{string.Join(",", req.PreferredBrands ?? Array.Empty<string>())}]",
            DateTimeOffset.UtcNow));

        // 1) Plan
        await EmitAsync(new AgentTrace(_chat.Name, "plan-begin", "rewriting brief into search query...", DateTimeOffset.UtcNow));
        var plan = await _chat.RespondAsync(
            systemPrompt:
                "You convert an interior-designer's natural-language brief into a single concise " +
                "search query for a bathroom-fittings catalog. Return ONLY the query, no quotes.",
            userPrompt: req.Prompt,
            ct: ct);
        plan = string.IsNullOrWhiteSpace(plan) ? req.Prompt : plan.Trim();
        await EmitAsync(new AgentTrace(_chat.Name, "plan", plan, DateTimeOffset.UtcNow));
        _log.LogInformation("Plan: {Plan}", plan);

        // 2) Retrieve
        await EmitAsync(new AgentTrace(_search.Name, "retrieve-begin", "querying brand catalog indexes...", DateTimeOffset.UtcNow));
        var items = await _search.FindAsync(plan, req.PreferredBrands, ct);

        // Rewrite each item's ImageUrl to the per-page PDF proxy on THIS service.
        // The proxy authenticates with managed identity to fetch the source PDF
        // from the private blob, extracts only the requested page using PdfPig,
        // and streams it back inline. This works around allowBlobPublicAccess=false
        // and gives the user a precise reference (e.g. "Parryware page 8") instead
        // of the whole PDF blob URL (which they couldn't open anyway).
        items = items.Select(i =>
        {
            if (string.IsNullOrWhiteSpace(i.SourceFile)) return i;
            var qs = $"brand={Uri.EscapeDataString(i.Brand)}&file={Uri.EscapeDataString(i.SourceFile)}";
            if (i.PageNumber is > 0) qs += $"&page={i.PageNumber}";
            return i with { ImageUrl = $"/api/catalog/page?{qs}" };
        }).ToList();

        await EmitAsync(new AgentTrace(_search.Name, "retrieve",
            $"{items.Count} products: " + string.Join("; ", items.Select(i => $"{i.Brand}/{i.Name}" + (i.PageNumber is > 0 ? $" (p.{i.PageNumber})" : ""))),
            DateTimeOffset.UtcNow));

        // 2.5) Mark TOP MATCHES from Foundry IQ's semantic ranking.
        //
        // We removed the previous vision-grounding step (gpt-4.1-mini Vision
        // describing each hero image -> feeding text back to MAI) because:
        //   * MAI is text-to-image; it cannot reproduce exact catalog products
        //     no matter how precise the description, so the extra ~6-10s of
        //     vision calls per turn delivered marginal MAI fidelity.
        //   * The "Fittings you may like" UI section (powered by Foundry IQ's
        //     semantic ranking + a per-page hero image proxy) honestly answers
        //     the user's real question - "what real products match my brief?"
        //   * Removing it gives a snappier turn, simpler architecture, and a
        //     cleaner blog narrative: MAI for inspiration, Foundry IQ for
        //     shoppable discovery, two distinct capabilities side by side.
        //
        // What we keep:
        //   * The CatalogPageImageExtractor service (still used by the
        //     /api/catalog/page-image endpoint to stream the inline hero JPEG
        //     into each TOP MATCH card).
        //   * The UsedAsVisualReference flag on CatalogItem - now repurposed
        //     as "this is one of Foundry IQ's top 2 page-level matches" so
        //     the UI badge + inline hero rendering keep working.
        var topMatchIds = items
            .Where(i => i.PageNumber is > 0 && !string.IsNullOrWhiteSpace(i.SourceFile))
            .OrderByDescending(i => i.Score ?? 0)
            .Take(2)
            .Select(i => i.Id)
            .ToHashSet(StringComparer.Ordinal);

        items = items
            .Select(i => topMatchIds.Contains(i.Id) ? i with { UsedAsVisualReference = true } : i)
            .OrderByDescending(i => i.UsedAsVisualReference)
            .ThenByDescending(i => i.Score ?? 0)
            .ToList();

        // 3) Compose - grounded in the text descriptions from AI Search. The
        // narrative names each retrieved product; the image-gen prompt produces
        // an inspirational interpretation; the matched catalog items appear
        // verbatim under the rendered image in the "Fittings you may like"
        // section, with one-click links to the source PDF page.
        var styles = req.StyleHints is { Count: > 0 } ? string.Join(", ", req.StyleHints) : "modern, minimalist";

        static string ProductLine(CatalogItem i)
        {
            var head = $"- {i.Brand} {i.Name} ({i.Category})";
            if (string.IsNullOrWhiteSpace(i.Description)) return head;
            // Trim each product's description so the compose prompt stays bounded.
            var d = i.Description.Replace('\n', ' ').Replace('\r', ' ').Trim();
            if (d.Length > 380) d = d.Substring(0, 380) + "\u2026";
            return head + "\n    " + d;
        }

        var composeUser = $$"""
            Designer brief: {{req.Prompt}}
            Style hints (USER-SELECTED, treat these as MANDATORY style direction): {{styles}}

            Matched products from Foundry IQ catalog search (these will appear under the
            rendered image as a "Fittings you may like" gallery; reference them by name in
            the narrative but the rendered scene is a creative interpretation, not a
            product-photo clone):
            {{string.Join("\n", items.Select(ProductLine))}}

            Write TWO sections separated by '---':

            SECTION A (markdown narrative for the designer, 4-6 sentences). Mention each product
            by name AND explicitly call out how the user's style hints ({{styles}}) shape the
            final design - finishes, materials, palette, lighting mood. End with one short
            closing sentence inviting the designer to review the matched catalog fittings shown
            below the rendered image (e.g. "Take a look at the matching Jaguar and Parryware
            fittings below - they were surfaced from your catalogs and may be worth specifying.").

            SECTION B (single paragraph image-generation prompt for a photo-realistic modern
            bathroom).

            Rules for SECTION B:
              1. The style hints "{{styles}}" govern the OVERALL aesthetic - walls, floor,
                 lighting, palette, materials, mood:
                   - 'modern, minimalist'      -> clean lines, low clutter, neutral palette
                   - 'luxury, marble'          -> veined marble walls/floor, brass or gold accents, warm uplighting
                   - 'scandinavian, light wood'-> oak vanity, white walls, natural daylight
                   - 'industrial, matte black' -> exposed concrete, blackened steel, edison-style fixtures
              2. Use the catalog-description vocabulary (finishes, materials, mounting style)
                 from the matched products above to inform fixture choices, but do NOT try to
                 reproduce specific catalog product photography - this is an inspirational
                 visualization, not a product render.
              3. Include camera angle (eye-level wide shot), lens (24mm), lighting (soft
                 daylight from a frosted window), and composition.
              4. Do NOT mention PDFs, catalogs, model codes, prices, page numbers, or filenames.
            """;
        await EmitAsync(new AgentTrace(_chat.Name, "compose-begin", "writing narrative + image prompt...", DateTimeOffset.UtcNow));
        var composed = await _chat.RespondAsync(
            systemPrompt: "You are a senior interior-design copywriter and prompt engineer.",
            userPrompt: composeUser,
            ct: ct);
        var (narrative, imagePrompt) = SplitSections(composed, fallback: req.Prompt);
        await EmitAsync(new AgentTrace(_chat.Name, "compose", Truncate(imagePrompt, 400), DateTimeOffset.UtcNow));

        // 5) Render
        byte[] png;
        Uri? blobUri = null;
        string? base64 = null;
        try
        {
            await EmitAsync(new AgentTrace(_imageGen.Name, "render-begin", "calling MAI image model (this can take 20-40s)...", DateTimeOffset.UtcNow));
            png = await _imageGen.GenerateAsync(imagePrompt, ct);
            if (png.Length > 0)
            {
                blobUri = await _store.SaveAsync(png, conversationId, ct);
                base64 = Convert.ToBase64String(png);
            }
            await EmitAsync(new AgentTrace(_imageGen.Name, "render",
                png.Length > 0 ? $"{png.Length / 1024} KB image" : "no image returned",
                DateTimeOffset.UtcNow));
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Image generation failed");
            await EmitAsync(new AgentTrace(_imageGen.Name, "render-error", ex.Message, DateTimeOffset.UtcNow));
        }

        sw.Stop();
        await EmitAsync(new AgentTrace("orchestrator", "done", $"{sw.ElapsedMilliseconds} ms", DateTimeOffset.UtcNow));

        return new DesignResponse(
            ConversationId: conversationId,
            Narrative: narrative,
            Selections: items,
            GeneratedImageUrl: blobUri?.ToString(),
            GeneratedImageBase64: base64,
            Trace: trace);
    }

    private static (string narrative, string imagePrompt) SplitSections(string composed, string fallback)
    {
        if (string.IsNullOrWhiteSpace(composed)) return (fallback, fallback);
        var parts = composed.Split("---", 2, StringSplitOptions.TrimEntries);
        if (parts.Length == 2) return (Strip(parts[0]), Strip(parts[1]));
        // No separator -> use the whole text for both, image prompt is original brief.
        return (composed.Trim(), fallback);

        static string Strip(string s)
        {
            // remove leading "SECTION A" / "SECTION B" labels if the model echoed them
            foreach (var label in new[] { "SECTION A", "SECTION B", "Section A", "Section B" })
                if (s.StartsWith(label, StringComparison.OrdinalIgnoreCase))
                    s = s[label.Length..].TrimStart(':', ' ', '\n', '\r');
            return s.Trim();
        }
    }

    private static string Truncate(string s, int max) => s.Length <= max ? s : s[..max] + "…";

    /// <summary>
    /// Compact filename for trace messages: drop common suffixes
    /// ("-pages-deleted-pages-1.pdf") so the user can read the trace at a glance
    /// instead of seeing 80-char filenames repeated every line.
    /// </summary>
    private static string ShortFile(string? file)
    {
        if (string.IsNullOrEmpty(file)) return "";
        var stem = System.IO.Path.GetFileNameWithoutExtension(file);
        // Drop the "-pages-deleted-pages-N" suffix our pre-trim script left behind.
        var idx = stem.IndexOf("-pages-deleted", StringComparison.OrdinalIgnoreCase);
        if (idx > 0) stem = stem.Substring(0, idx);
        // Drop trailing "(N)" duplicate markers.
        stem = System.Text.RegularExpressions.Regex.Replace(stem, @"\s*\(\d+\)\s*$", "");
        return stem;
    }
}
