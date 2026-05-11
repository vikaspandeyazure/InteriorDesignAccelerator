using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Core;

namespace InteriorDesign.Orchestrator.Foundry;

/// <summary>
/// Calls a NEW Foundry hosted agent via the OpenAI-compatible Responses API:
///   POST {projectEndpoint}/agents/{agentName}/endpoint/protocols/openai/responses?api-version=2025-11-15-preview
///
/// The agent is pre-created (kind=prompt; model + instructions baked in) by deploy.ps1
/// Phase 8c. At runtime the orchestrator just POSTs the user input and reads the
/// assistant text from the response.
/// </summary>
public sealed class FoundryResponsesClient
{
    private const string ApiVersion = "2025-11-15-preview";
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
    private static readonly string[] Scopes = new[] { "https://ai.azure.com/.default" };

    private readonly HttpClient _http;
    private readonly TokenCredential _credential;
    private readonly string _projectEndpoint;

    public FoundryResponsesClient(HttpClient http, TokenCredential credential, string projectEndpoint)
    {
        _http = http;
        _credential = credential;
        _projectEndpoint = projectEndpoint?.TrimEnd('/') ?? throw new ArgumentNullException(nameof(projectEndpoint));
    }

    public Task<string> InvokeAsync(string agentName, string userInput, CancellationToken ct = default)
        => SendAsync(agentName, BuildTextOnlyBody(userInput), ct);

    public Task<string> InvokeMultimodalAsync(string agentName, string userText, IReadOnlyList<string> imageUrls, CancellationToken ct = default)
        => SendAsync(agentName, BuildMultimodalBody(userText, imageUrls), ct);

    private static object BuildTextOnlyBody(string userInput) => new
    {
        input = new object[]
        {
            new { role = "user", content = new object[] { new { type = "input_text", text = userInput } } }
        }
    };

    private static object BuildMultimodalBody(string userText, IReadOnlyList<string> imageUrls)
    {
        var parts = new List<object> { new { type = "input_text", text = userText } };
        foreach (var u in imageUrls.Where(u => !string.IsNullOrWhiteSpace(u)))
            parts.Add(new { type = "input_image", image_url = u });
        return new
        {
            input = new object[]
            {
                new { role = "user", content = parts.ToArray() }
            }
        };
    }

    private async Task<string> SendAsync(string agentName, object body, CancellationToken ct)
    {
        var token = await _credential.GetTokenAsync(new TokenRequestContext(Scopes), ct);
        var url = $"{_projectEndpoint}/agents/{Uri.EscapeDataString(agentName)}/endpoint/protocols/openai/responses?api-version={ApiVersion}";
        using var req = new HttpRequestMessage(HttpMethod.Post, url) { Content = JsonContent.Create(body, options: JsonOpts) };
        req.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);

        using var resp = await _http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, ct);
        var raw = await resp.Content.ReadAsStringAsync(ct);
        if (!resp.IsSuccessStatusCode)
            throw new InvalidOperationException($"Foundry responses API {(int)resp.StatusCode} for agent '{agentName}': {raw}");
        return ExtractText(raw);
    }

    /// <summary>
    /// Walk the OpenAI Responses output structure and concatenate text parts.
    /// Output shape: { output: [ { type:"message", content: [ { type:"output_text", text:"..." } ] } ] }
    /// Some Foundry versions also include a top-level convenience "output_text" string.
    /// </summary>
    private static string ExtractText(string rawJson)
    {
        try
        {
            using var doc = JsonDocument.Parse(rawJson);
            if (doc.RootElement.TryGetProperty("output_text", out var ot) && ot.ValueKind == JsonValueKind.String)
                return ot.GetString() ?? string.Empty;

            if (!doc.RootElement.TryGetProperty("output", out var output) || output.ValueKind != JsonValueKind.Array)
                return rawJson;

            var sb = new System.Text.StringBuilder();
            foreach (var msg in output.EnumerateArray())
            {
                if (!msg.TryGetProperty("content", out var content) || content.ValueKind != JsonValueKind.Array) continue;
                foreach (var part in content.EnumerateArray())
                {
                    if (part.TryGetProperty("text", out var txt) && txt.ValueKind == JsonValueKind.String)
                        sb.AppendLine(txt.GetString());
                }
            }
            var s = sb.ToString().Trim();
            return s.Length == 0 ? rawJson : s;
        }
        catch { return rawJson; }
    }
}
