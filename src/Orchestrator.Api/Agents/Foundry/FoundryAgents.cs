using Azure.Core;
using InteriorDesign.Orchestrator.Foundry;
using InteriorDesign.Orchestrator.Options;
using InteriorDesign.Orchestrator.Services;
using InteriorDesign.Shared.Contracts;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace InteriorDesign.Orchestrator.Agents.Foundry;

// All four agents talk to NEW Foundry hosted agents via the Responses API.
//   chat-agent                 -> compose narrative + image prompt
//   catalog-search-agent       -> RANK/FILTER products. Real retrieval is done first
//                                  by CatalogSearchService against the 2 brand-specific
//                                  indexes (jaguar-catalog, parryware-catalog) - these
//                                  are also surfaced in Foundry portal under Knowledge.
//   vision-understanding-agent -> CU runs first to extract structured visual specs;
//                                  results are handed to the Foundry agent for narrative.
//   image-gen-agent            -> Foundry agent refines the prompt; orchestrator then
//                                  calls the MAI image deployment for the binary image
//                                  (Foundry prompt agents cannot return binary).

internal sealed class FoundryChatAgent : IChatAgent
{
    private readonly FoundryResponsesClient _client;
    private readonly string _agentName;
    public string Name => "foundry-chat-agent";

    public FoundryChatAgent(FoundryResponsesClient client, string agentName)
    { _client = client; _agentName = agentName; }

    public Task<string> RespondAsync(string systemPrompt, string userPrompt, CancellationToken ct = default)
    {
        var combined = string.IsNullOrWhiteSpace(systemPrompt)
            ? userPrompt
            : $"{systemPrompt}\n\n---\n\n{userPrompt}";
        return _client.InvokeAsync(_agentName, combined, ct);
    }

    public Task<string> RespondWithImagesAsync(
        string systemPrompt,
        string userPrompt,
        IReadOnlyList<string> imageDataUrls,
        CancellationToken ct = default)
    {
        var combined = string.IsNullOrWhiteSpace(systemPrompt)
            ? userPrompt
            : $"{systemPrompt}\n\n---\n\n{userPrompt}";
        return _client.InvokeMultimodalAsync(_agentName, combined, imageDataUrls, ct);
    }
}

internal sealed class FoundryCatalogSearchAgent : ICatalogSearchAgent
{
    private readonly FoundryResponsesClient _client;
    private readonly CatalogSearchService _search;
    private readonly string _agentName;
    public string Name => "foundry-catalog-search-agent";

    public FoundryCatalogSearchAgent(FoundryResponsesClient client, CatalogSearchService search, string agentName)
    {
        _client = client;
        _search = search;
        _agentName = agentName;
    }

    public async Task<IReadOnlyList<CatalogItem>> FindAsync(string query, IReadOnlyList<string>? brandFilter, CancellationToken ct = default)
    {
        // STEP A: Real retrieval against the 2 brand-specific AI Search indexes
        // (jaguar-catalog + parryware-catalog). The orchestrator runs the
        // search itself - this is the canonical, working flow.
        //
        // We deliberately do NOT depend on the catalog-search-agent's own
        // knowledge bindings to do retrieval. Per portal evidence the agents
        // /versions endpoint silently drops 'knowledge' / 'knowledge_bases' /
        // 'knowledgeSources' fields on the current preview surface, leaving
        // the agent ungrounded server-side. If we trusted the agent for
        // retrieval, the user would get zero results.
        var retrieved = await _search.SearchAsync(query, brandFilter, top: 12, ct);
        if (retrieved.Count == 0) return retrieved;

        // STEP B: Foundry catalog-search-agent acts as a RE-RANKER. We hand it
        // the 12 candidates (so it doesn't need its own knowledge bindings to
        // see the data) and ask it to pick the best 8 in priority order. The
        // agent's job is judgment over text, not retrieval.
        var brands = brandFilter is { Count: > 0 } ? string.Join(", ", brandFilter) : "any";
        var asJson = JsonSerializer.Serialize(retrieved.Select(r => new
        {
            r.Id, r.Brand, r.Category, r.Name, r.Description, r.ImageUrl, r.Score
        }));
        var ask =
            $"User design brief: {query}\n" +
            $"Brand scope: {brands}\n" +
            $"Retrieved candidates from AI Search ({retrieved.Count}):\n{asJson}\n\n" +
            "Pick the BEST up-to-8 products that match the brief, dedup similar items, " +
            "and return ONLY a JSON array of {id,brand,category,name,description,imageUrl} " +
            "in priority order. No prose, no markdown.";

        try
        {
            var raw = await _client.InvokeAsync(_agentName, ask, ct);
            var ranked = ParseItems(raw);
            if (ranked.Count == 0) return retrieved.Take(8).ToList();

            // CRITICAL: the agent only returns the {id,brand,category,name,
            // description,imageUrl} subset, so SourceFile / PageNumber / Score
            // are LOST in the agent round-trip. We re-join the agent's ranked
            // Id list against the original AI Search retrieval to restore those
            // fields - they are the real grounding signal the rest of the
            // pipeline depends on (per-page PDF proxy, /api/catalog/page-rendered
            // thumbnails, the TOP MATCH badge). The agent's contribution is
            // ORDER + FILTER. If the agent hallucinates an Id not in the
            // retrieval, we drop it - the pipeline only passes through items
            // grounded in the actual catalog index.
            var byId = retrieved.ToDictionary(r => r.Id, r => r, StringComparer.Ordinal);
            var merged = new List<CatalogItem>(ranked.Count);
            foreach (var r in ranked)
            {
                if (byId.TryGetValue(r.Id, out var original))
                {
                    merged.Add(original);
                }
            }
            return merged.Count > 0 ? merged : retrieved.Take(8).ToList();
        }
        catch
        {
            // Agent failed -> fall through with the raw retrieval (still real
            // data in AI Search relevance order, no hallucination risk).
            return retrieved.Take(8).ToList();
        }
    }

    private static IReadOnlyList<CatalogItem> ParseItems(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return Array.Empty<CatalogItem>();
        var open  = raw.IndexOf('[');
        var close = raw.LastIndexOf(']');
        if (open < 0 || close <= open) return Array.Empty<CatalogItem>();
        try
        {
            using var doc = JsonDocument.Parse(raw[open..(close + 1)]);
            if (doc.RootElement.ValueKind != JsonValueKind.Array) return Array.Empty<CatalogItem>();
            var list = new List<CatalogItem>();
            foreach (var el in doc.RootElement.EnumerateArray())
            {
                int? page = null;
                if (el.TryGetProperty("pageNumber", out var pv) && pv.ValueKind == JsonValueKind.Number && pv.TryGetInt32(out var pi))
                    page = pi;
                list.Add(new CatalogItem(
                    Id:          GetString(el, "id"),
                    Brand:       GetString(el, "brand"),
                    Category:    GetString(el, "category"),
                    Name:        GetString(el, "name"),
                    Description: GetString(el, "description"),
                    ImageUrl:    GetString(el, "imageUrl"),
                    Score:       null,
                    SourceFile:  GetString(el, "sourceFile"),
                    PageNumber:  page));
            }
            return list;
        }
        catch { return Array.Empty<CatalogItem>(); }
    }

    private static string GetString(JsonElement el, string name)
        => el.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String
            ? (v.GetString() ?? string.Empty)
            : string.Empty;
}

internal sealed class FoundryImageGenAgent : IImageGenAgent
{
    private static readonly string[] AadScopes = new[] { "https://cognitiveservices.azure.com/.default" };

    private readonly FoundryResponsesClient _client;
    private readonly string _agentName;
    private readonly TokenCredential _credential;
    private readonly Uri _maiEndpoint;
    private readonly string _modelDeployment;
    private readonly HttpClient _http;

    public string Name => "foundry-image-gen-agent";

    public FoundryImageGenAgent(FoundryResponsesClient client, string agentName, IOptions<AzureOptions> opts, TokenCredential credential)
    {
        _client = client;
        _agentName = agentName;
        _credential = credential;
        if (string.IsNullOrWhiteSpace(opts.Value.FoundryAccountEndpoint))
            throw new InvalidOperationException("Azure:FoundryAccountEndpoint is required for image generation.");
        _modelDeployment = opts.Value.ImageModelDeployment;

        // MAI-Image-2 (and other Microsoft-published Foundry image models) live
        // on a DEDICATED inference surface, NOT the Azure OpenAI surface:
        //
        //   POST https://<account>.services.ai.azure.com/mai/v1/images/generations
        //   {
        //     "model": "mai-image-2",
        //     "prompt": "...",
        //     "width":  1024,
        //     "height": 1024
        //   }
        //
        // Confirmed from the Foundry portal "View code" sample for the
        // deployment AND verified end-to-end with a 200 OK + 962 KB PNG using
        // the deployer's AAD token (resource = cognitiveservices.azure.com).
        //
        // Things that DO NOT work for MAI:
        //   * /openai/v1/images/generations  ........ "unknown_model"
        //   * /openai/deployments/{depl}/images/...    "unknown_model" on BOTH
        //                                              services.ai.azure.com and
        //                                              cognitiveservices.azure.com hosts
        //
        // Reason: MAI is `format: Microsoft`. The Azure OpenAI route only
        // resolves OpenAI-published deployments. Microsoft-published models
        // are served at /mai/v1/. (For OpenAI image models like DALL-E we
        // would route to /openai/deployments/.../images/generations - we
        // do not need that here because we deploy MAI exclusively.)
        var rawEndpoint = opts.Value.FoundryAccountEndpoint.TrimEnd('/');
        // Derive the Foundry host (services.ai.azure.com) from the legacy
        // cognitiveservices.azure.com endpoint that the bicep emits.
        var foundryHost = rawEndpoint.Replace(".cognitiveservices.azure.com", ".services.ai.azure.com", StringComparison.OrdinalIgnoreCase);
        _maiEndpoint = new Uri($"{foundryHost}/mai/v1/images/generations");
        _http = new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
    }

    public async Task<byte[]> GenerateAsync(string prompt, CancellationToken ct = default)
    {
        string refined;
        try
        {
            refined = await _client.InvokeAsync(_agentName, prompt, ct);
            if (string.IsNullOrWhiteSpace(refined)) refined = prompt;
        }
        catch { refined = prompt; }

        // Acquire AAD token directly so we control refresh & failure surfacing.
        var token = await _credential.GetTokenAsync(new TokenRequestContext(AadScopes), ct);

        // MAI body shape: model + prompt + width/height (NOT size: "1024x1024").
        // NOTE: do NOT pass response_format - mai-image-2 rejects it with
        // "Model does not support request argument supplied: Invalid
        // parameters: response_format". MAI decides on its own whether to
        // return inline 'b64_json' or a 'url'; we handle both shapes below,
        // and the URL path attaches our Bearer token so the storage GET
        // succeeds (the URL points at an authenticated Foundry blob).
        var body = JsonSerializer.Serialize(new
        {
            model  = _modelDeployment,
            prompt = refined,
            width  = 1024,
            height = 1024
        });

        // Retry on 429 (real RPM rate-limit; MAI on S0 is 1 RPM by default) and
        // transient 5xx. Refresh token once on 401/403. Surface a clear,
        // actionable error otherwise so the live trace panel is diagnostic.
        Exception? last = null;
        int[] delaysSec = { 30, 45, 70, 90 };

        for (int attempt = 0; attempt < delaysSec.Length + 1; attempt++)
        {
            try
            {
                using var req = new HttpRequestMessage(HttpMethod.Post, _maiEndpoint)
                {
                    Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json")
                };
                req.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token.Token);

                using var resp = await _http.SendAsync(req, ct);
                if (resp.IsSuccessStatusCode)
                {
                    var json = await resp.Content.ReadAsStringAsync(ct);
                    using var doc = JsonDocument.Parse(json);
                    if (doc.RootElement.TryGetProperty("data", out var data) &&
                        data.ValueKind == JsonValueKind.Array && data.GetArrayLength() > 0)
                    {
                        var first = data[0];
                        if (first.TryGetProperty("b64_json", out var b64El) && b64El.ValueKind == JsonValueKind.String)
                        {
                            var b64 = b64El.GetString();
                            if (!string.IsNullOrEmpty(b64)) return Convert.FromBase64String(b64);
                        }
                        if (first.TryGetProperty("url", out var urlEl) && urlEl.ValueKind == JsonValueKind.String)
                        {
                            var url = urlEl.GetString();
                            if (!string.IsNullOrEmpty(url))
                            {
                                // Defensive fallback only - response_format='b64_json' above means
                                // MAI normally returns inline bytes. If a deployment ignores the
                                // hint and still returns a URL, that URL points at an authenticated
                                // Foundry-hosted blob; attach the same Bearer token we used for
                                // the POST so the GET succeeds. Anonymous GET would 403 with
                                // "AuthorizationFailure" (Storage data plane).
                                using var imgReq = new HttpRequestMessage(HttpMethod.Get, url);
                                imgReq.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token.Token);
                                using var imgResp = await _http.SendAsync(imgReq, ct);
                                if (imgResp.IsSuccessStatusCode)
                                    return await imgResp.Content.ReadAsByteArrayAsync(ct);
                            }
                        }
                    }
                    return Array.Empty<byte>();
                }

                var status = (int)resp.StatusCode;
                var errBody = await resp.Content.ReadAsStringAsync(ct);
                var trimmed = errBody.Length > 400 ? errBody.Substring(0, 400) + "\u2026" : errBody;

                if ((status == 401 || status == 403) && attempt < delaysSec.Length)
                {
                    token = await _credential.GetTokenAsync(new TokenRequestContext(AadScopes), ct);
                    last = new HttpRequestException($"HTTP {status}: {trimmed}");
                    await Task.Delay(TimeSpan.FromSeconds(5), ct);
                    continue;
                }
                if (status == 429 && attempt < delaysSec.Length)
                {
                    last = new HttpRequestException($"HTTP 429 (rate limited - MAI S0 is 1 RPM): {trimmed}");
                    await Task.Delay(TimeSpan.FromSeconds(delaysSec[attempt]), ct);
                    continue;
                }
                if (status >= 500 && status < 600 && attempt < delaysSec.Length)
                {
                    last = new HttpRequestException($"HTTP {status}: {trimmed}");
                    await Task.Delay(TimeSpan.FromSeconds(delaysSec[attempt]), ct);
                    continue;
                }

                throw new InvalidOperationException(
                    $"MAI image generation failed (HTTP {status}) at {_maiEndpoint.AbsoluteUri} with model='{_modelDeployment}': {trimmed}");
            }
            catch (TaskCanceledException) when (ct.IsCancellationRequested)
            {
                throw;
            }
            catch (HttpRequestException ex) when (attempt < delaysSec.Length)
            {
                last = ex;
                await Task.Delay(TimeSpan.FromSeconds(delaysSec[attempt]), ct);
                continue;
            }
        }
        throw last ?? new InvalidOperationException(
            $"MAI image generation failed after retries at {_maiEndpoint.AbsoluteUri} with model='{_modelDeployment}'.");
    }
}
