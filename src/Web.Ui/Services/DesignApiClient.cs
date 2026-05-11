using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using InteriorDesign.Shared.Contracts;

namespace InteriorDesign.Web.Ui.Services;

public sealed class DesignApiClient
{
    private static readonly JsonSerializerOptions JsonOpts = new(JsonSerializerDefaults.Web);

    private readonly HttpClient _http;
    public DesignApiClient(HttpClient http) => _http = http;

    /// <summary>
    /// Base address of the orchestrator (set in Program.cs via DI). Used by
    /// the UI to build absolute URLs to orchestrator-served resources such as
    /// the per-page PDF proxy at /api/catalog/page.
    /// </summary>
    public Uri? BaseAddress => _http.BaseAddress;

    /// <summary>
    /// Resolves a relative orchestrator path (e.g. "/api/catalog/page?...")
    /// to an absolute URL that the browser can navigate to. If the input is
    /// already absolute, returns it unchanged.
    /// </summary>
    public string ToAbsoluteUrl(string? relativeOrAbsolute)
    {
        if (string.IsNullOrWhiteSpace(relativeOrAbsolute)) return string.Empty;
        if (Uri.TryCreate(relativeOrAbsolute, UriKind.Absolute, out var abs)) return abs.ToString();
        if (BaseAddress is null) return relativeOrAbsolute;
        return new Uri(BaseAddress, relativeOrAbsolute).ToString();
    }

    public async Task<DesignResponse?> GenerateAsync(DesignRequest req, CancellationToken ct = default)
    {
        var resp = await _http.PostAsJsonAsync("/api/design/generate", req, ct);
        resp.EnsureSuccessStatusCode();
        return await resp.Content.ReadFromJsonAsync<DesignResponse>(cancellationToken: ct);
    }

    /// <summary>
    /// GETs an orchestrator path using the typed HttpClient (which already
    /// carries the APIM subscription key) and returns the raw response so
    /// callers can stream it back to the browser. Used by the catalog page
    /// image proxy endpoints in <c>Program.cs</c> so the browser never has to
    /// reach the orchestrator directly - this works around (a) APIM auth in
    /// Azure (browser has no subscription-key header) and (b) local port
    /// mismatches between Web.Ui's configured Orchestrator:BaseUrl and the
    /// orchestrator's dev launch profile.
    /// </summary>
    public Task<HttpResponseMessage> GetRawAsync(string relativePath, CancellationToken ct = default)
    {
        return _http.GetAsync(relativePath, HttpCompletionOption.ResponseHeadersRead, ct);
    }

    /// <summary>
    /// Streams individual <see cref="StreamEvent"/>s from POST /api/design/generate/stream
    /// (Server-Sent Events). Each yielded event is one of:
    ///   * Kind="trace" with <see cref="StreamEvent.Trace"/> populated (one per agent step)
    ///   * Kind="done"  with <see cref="StreamEvent.Final"/> populated (final DesignResponse)
    ///   * Kind="error" with <see cref="StreamEvent.Error"/> populated
    /// </summary>
    public async IAsyncEnumerable<StreamEvent> GenerateStreamAsync(
        DesignRequest req,
        [System.Runtime.CompilerServices.EnumeratorCancellation] CancellationToken ct = default)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/api/design/generate/stream")
        {
            Content = JsonContent.Create(req, options: JsonOpts)
        };
        request.Headers.Accept.ParseAdd("text/event-stream");

        using var resp = await _http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();

        await using var stream = await resp.Content.ReadAsStreamAsync(ct);
        using var reader = new StreamReader(stream, Encoding.UTF8);

        string? currentEvent = null;
        var dataBuf = new StringBuilder();

        while (!reader.EndOfStream)
        {
            ct.ThrowIfCancellationRequested();
            var line = await reader.ReadLineAsync(ct);
            if (line is null) break;

            if (line.Length == 0)
            {
                // Blank line = end of one event. Dispatch what we collected.
                if (currentEvent is not null && dataBuf.Length > 0)
                {
                    var data = dataBuf.ToString();
                    var ev = currentEvent switch
                    {
                        "trace" => new StreamEvent("trace", JsonSerializer.Deserialize<AgentTrace>(data, JsonOpts), null, null),
                        "done"  => new StreamEvent("done", null, JsonSerializer.Deserialize<DesignResponse>(data, JsonOpts), null),
                        "error" => new StreamEvent("error", null, null, data),
                        _       => new StreamEvent(currentEvent, null, null, data)
                    };
                    yield return ev;
                }
                currentEvent = null;
                dataBuf.Clear();
                continue;
            }
            if (line.StartsWith(':')) continue;       // SSE comment / heartbeat
            if (line.StartsWith("event:"))            { currentEvent = line.Substring(6).Trim(); }
            else if (line.StartsWith("data:"))        { dataBuf.AppendLine(line.Substring(5).TrimStart()); }
            // (id: / retry: are ignored - we don't reconnect mid-pipeline)
        }
    }

    public sealed record StreamEvent(string Kind, AgentTrace? Trace, DesignResponse? Final, string? Error);
}
