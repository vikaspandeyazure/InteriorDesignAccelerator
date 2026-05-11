namespace InteriorDesign.Shared.Contracts;

/// <summary>
/// Request from the UI to the orchestrator.
/// </summary>
/// <param name="Prompt">Free-form designer prompt e.g. "modern bathroom with Jaguar wall-mount basin and Parryware rain shower".</param>
/// <param name="PreferredBrands">Optional brand filter. Empty == any.</param>
/// <param name="StyleHints">Optional style words: minimalist, scandinavian, luxury, etc.</param>
/// <param name="ConversationId">Stable id for multi-turn chat. Null on first turn.</param>
public sealed record DesignRequest(
    string Prompt,
    IReadOnlyList<string>? PreferredBrands = null,
    IReadOnlyList<string>? StyleHints = null,
    string? ConversationId = null);

/// <summary>
/// One product picked from the AI Search catalog index.
/// </summary>
/// <param name="ImageUrl">URL the UI uses to OPEN the source. For text-extracted catalog
/// pages this points at the orchestrator's per-page PDF proxy
/// (/api/catalog/page?brand=...&amp;file=...&amp;page=N), which extracts JUST that page from
/// the source PDF in private blob storage and streams it back. For brand-profile entries
/// (image-only PDFs that yielded no text - e.g. Jaguar Laguna scans) it points at the
/// whole-PDF proxy (/api/catalog/page?brand=...&amp;file=...).</param>
/// <param name="SourceFile">Original PDF filename in catalogs/{brand}/. Carried so the UI
/// can show "Parryware-Pricelist-Feb-2026 (page 8)" labels under each product card.</param>
/// <param name="PageNumber">1-based page number when the entry came from a specific PDF page.
/// 0 (or null) for brand-profile entries that span the whole document.</param>
/// <param name="UsedAsVisualReference">True when this product's hero image was extracted
/// from its PDF page and fed to gpt-4.1-mini Vision, whose description was then woven
/// into the MAI image-gen prompt. Lets the UI mark exactly which references shaped
/// the rendered bathroom (vs. retrieved-but-not-grounded items).</param>
/// <param name="VisualDescription">When UsedAsVisualReference is true, the verbatim
/// vision description (shape, finish, mounting, accents) that was passed to MAI.
/// Surfaces the multimodal grounding for the user.</param>
public sealed record CatalogItem(
    string Id,
    string Brand,
    string Category,
    string Name,
    string? Description,
    string? ImageUrl,
    double? Score,
    string? SourceFile = null,
    int? PageNumber = null,
    bool UsedAsVisualReference = false,
    string? VisualDescription = null);

/// <summary>
/// Result returned to the UI.
/// </summary>
public sealed record DesignResponse(
    string ConversationId,
    string Narrative,
    IReadOnlyList<CatalogItem> Selections,
    string? GeneratedImageUrl,
    string? GeneratedImageBase64,
    IReadOnlyList<AgentTrace> Trace);

/// <summary>
/// Lightweight per-agent trace for the demo UI.
/// </summary>
public sealed record AgentTrace(
    string AgentName,
    string Step,
    string Detail,
    DateTimeOffset At);
