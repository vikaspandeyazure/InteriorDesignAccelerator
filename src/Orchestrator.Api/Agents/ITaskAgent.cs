using InteriorDesign.Shared.Contracts;

namespace InteriorDesign.Orchestrator.Agents;

/// <summary>
/// Single-task agent abstraction. Each concrete agent (chat, search, vision, image-gen)
/// implements one verb. The OrchestratorAgent composes them via the Microsoft Agent Framework.
/// </summary>
public interface ITaskAgent
{
    string Name { get; }
}

public interface IChatAgent : ITaskAgent
{
    Task<string> RespondAsync(string systemPrompt, string userPrompt, CancellationToken ct = default);

    /// <summary>
    /// Same as RespondAsync but with image inputs. Each item in
    /// <paramref name="imageDataUrls"/> must be either an https:// URL the
    /// agent can fetch OR a data: URL (data:image/jpeg;base64,...). Used
    /// during the visual-grounding step to describe embedded catalog images
    /// before image generation.
    /// </summary>
    Task<string> RespondWithImagesAsync(
        string systemPrompt,
        string userPrompt,
        IReadOnlyList<string> imageDataUrls,
        CancellationToken ct = default);
}

public interface ICatalogSearchAgent : ITaskAgent
{
    Task<IReadOnlyList<CatalogItem>> FindAsync(
        string query,
        IReadOnlyList<string>? brandFilter,
        CancellationToken ct = default);
}

public interface IImageGenAgent : ITaskAgent
{
    /// <summary>Generates a single 1024x1024 PNG and returns its bytes.</summary>
    Task<byte[]> GenerateAsync(string prompt, CancellationToken ct = default);
}
