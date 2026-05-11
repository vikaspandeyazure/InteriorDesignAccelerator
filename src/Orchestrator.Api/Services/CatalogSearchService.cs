using Azure;
using Azure.Search.Documents;
using Azure.Search.Documents.Models;
using InteriorDesign.Orchestrator.Options;
using InteriorDesign.Shared.Contracts;
using Microsoft.Extensions.Options;

namespace InteriorDesign.Orchestrator.Services;

/// <summary>
/// Queries the brand-specific AI Search indexes (jaguar-catalog, parryware-catalog).
/// One SearchClient per index. When the caller passes a brandFilter we only hit the
/// matching indexes; otherwise we fan out to all configured indexes.
/// </summary>
public sealed class CatalogSearchService
{
    // index name -> SearchClient
    private readonly Dictionary<string, SearchClient> _clients;
    // index name -> brand prefix (jaguar-catalog -> jaguar)
    private readonly Dictionary<string, string> _indexBrand;

    public CatalogSearchService(IReadOnlyDictionary<string, SearchClient> clients)
    {
        _clients = new Dictionary<string, SearchClient>(clients, StringComparer.OrdinalIgnoreCase);
        _indexBrand = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var k in _clients.Keys)
        {
            // jaguar-catalog -> jaguar, parryware-catalog -> parryware
            var brand = k.Replace("-catalog", "", StringComparison.OrdinalIgnoreCase).Trim();
            _indexBrand[k] = brand;
        }
    }

    public static CatalogSearchService Create(IOptions<AzureOptions> opts, Azure.Core.TokenCredential credential)
    {
        var o = opts.Value;
        if (string.IsNullOrWhiteSpace(o.SearchEndpoint))
            throw new InvalidOperationException("Azure:SearchEndpoint is required.");
        var indexes = (o.SearchIndexNames ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .ToArray();
        if (indexes.Length == 0) indexes = new[] { "jaguar-catalog", "parryware-catalog" };

        var clients = indexes.ToDictionary(
            idx => idx,
            idx => new SearchClient(new Uri(o.SearchEndpoint), idx, credential),
            StringComparer.OrdinalIgnoreCase);
        return new CatalogSearchService(clients);
    }

    public async Task<IReadOnlyList<CatalogItem>> SearchAsync(
        string query,
        IReadOnlyList<string>? brandFilter,
        int top = 8,
        CancellationToken ct = default)
    {
        // Decide which indexes to hit: filter -> only matching brand indexes.
        var targets = new List<string>();
        if (brandFilter is { Count: > 0 })
        {
            foreach (var (idx, brand) in _indexBrand)
            {
                if (brandFilter.Any(b => string.Equals(b, brand, StringComparison.OrdinalIgnoreCase)))
                    targets.Add(idx);
            }
        }
        if (targets.Count == 0) targets.AddRange(_clients.Keys);

        var perIndexTop = Math.Max(1, top / Math.Max(1, targets.Count));
        var results = new List<CatalogItem>();

        foreach (var idx in targets)
        {
            var brand = _indexBrand[idx];
            var client = _clients[idx];
            var options = new SearchOptions
            {
                Size = perIndexTop,
                QueryType = SearchQueryType.Semantic,
                SemanticSearch = new SemanticSearchOptions { SemanticConfigurationName = "default" }
            };
            try
            {
                var response = await client.SearchAsync<SearchDocument>(query, options, ct);
                await foreach (var hit in response.Value.GetResultsAsync())
                {
                    results.Add(MapDoc(hit, brand));
                }
            }
            catch (RequestFailedException ex) when (ex.Status == 400)
            {
                // Index doesn't have semantic config yet -> fall back to keyword
                options.QueryType = SearchQueryType.Simple;
                options.SemanticSearch = null;
                var response = await client.SearchAsync<SearchDocument>(query, options, ct);
                await foreach (var hit in response.Value.GetResultsAsync())
                {
                    results.Add(MapDoc(hit, brand));
                }
            }
            catch (RequestFailedException) { /* index may not exist yet (e.g. parryware not seeded) - ignore */ }
        }

        return results
            .OrderByDescending(r => r.Score ?? 0.0)
            .Take(top)
            .ToList();
    }

    private static CatalogItem MapDoc(SearchResult<SearchDocument> hit, string defaultBrand)
    {
        var doc = hit.Document;
        int? page = null;
        if (doc.TryGetValue("pageNumber", out var pageObj) && pageObj is not null)
        {
            if (pageObj is int pi) page = pi;
            else if (int.TryParse(pageObj.ToString(), out var pParsed)) page = pParsed;
        }
        return new CatalogItem(
            Id:          doc.TryGetValue("id", out var id) ? id?.ToString() ?? "" : "",
            Brand:       doc.TryGetValue("brand", out var b) && !string.IsNullOrWhiteSpace(b?.ToString()) ? b!.ToString()! : defaultBrand,
            Category:    doc.TryGetValue("category", out var c) ? c?.ToString() ?? "" : "",
            Name:        doc.TryGetValue("name", out var n) ? n?.ToString() ?? "" : "",
            Description: doc.TryGetValue("description", out var d) ? d?.ToString() : null,
            ImageUrl:    doc.TryGetValue("imageUrl", out var i) ? i?.ToString() : null,
            Score:       hit.Score,
            SourceFile:  doc.TryGetValue("sourceFile", out var sf) ? sf?.ToString() : null,
            PageNumber:  page);
    }
}
