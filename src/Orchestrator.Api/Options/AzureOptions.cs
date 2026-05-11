namespace InteriorDesign.Orchestrator.Options;

public sealed class AzureOptions
{
    public const string SectionName = "Azure";

    /// <summary>NEW Foundry project endpoint (services.ai.azure.com) for /agents data plane.</summary>
    public string FoundryProjectEndpoint { get; set; } = string.Empty;

    /// <summary>Foundry account inference endpoint (cognitiveservices.azure.com) for chat/image SDK calls.</summary>
    public string FoundryAccountEndpoint { get; set; } = string.Empty;

    public string ChatModelDeployment { get; set; } = "gpt-4.1-mini";
    public string ImageModelDeployment { get; set; } = "mai-image-2";

    public string SearchEndpoint { get; set; } = string.Empty;
    /// <summary>Comma-separated list of catalog index names (one per brand).</summary>
    public string SearchIndexNames { get; set; } = "jaguar-catalog,parryware-catalog";

    public string BlobAccountUrl { get; set; } = string.Empty;
    public string CatalogContainer { get; set; } = "catalogs";
    public string GeneratedContainer { get; set; } = "generated";

    /// <summary>Names (not IDs) of Foundry hosted agents.</summary>
    public FoundryAgentNames Agents { get; set; } = new();
}

public sealed class FoundryAgentNames
{
    public string CatalogSearchAgent { get; set; } = "catalog-search-agent";
    public string ChatAgent { get; set; } = "chat-agent";
    public string ImageGenAgent { get; set; } = "image-gen-agent";
}
