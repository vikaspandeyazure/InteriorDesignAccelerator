using System.Text.Json;
using InteriorDesign.Orchestrator.Agents;
using InteriorDesign.Shared.Contracts;
using Microsoft.AspNetCore.Http;

namespace InteriorDesign.Orchestrator.Endpoints;

public static class DesignEndpoints
{
    private static readonly JsonSerializerOptions SseJsonOpts = new(JsonSerializerDefaults.Web);

    public static IEndpointRouteBuilder MapDesignEndpoints(this IEndpointRouteBuilder app)
    {
        var grp = app.MapGroup("/api/design").WithTags("Design");

        grp.MapPost("/generate", async (
            DesignRequest req,
            OrchestratorAgent orchestrator,
            CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(req.Prompt))
                return Results.BadRequest(new { error = "Prompt is required." });

            var resp = await orchestrator.RunAsync(req, ct);
            return Results.Ok(resp);
        })
        .WithName("GenerateDesign");

        // Server-Sent Events endpoint that emits one `event: trace` per agent step
        // as soon as it completes, then a final `event: done` carrying the full
        // DesignResponse JSON. Powers the live Foundry-Playground-style trace
        // panel in the Web UI.
        grp.MapPost("/generate/stream", async (
            DesignRequest req,
            OrchestratorAgent orchestrator,
            HttpContext http,
            CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(req.Prompt))
            {
                http.Response.StatusCode = StatusCodes.Status400BadRequest;
                await http.Response.WriteAsJsonAsync(new { error = "Prompt is required." }, ct);
                return;
            }

            http.Response.Headers.ContentType = "text/event-stream";
            http.Response.Headers.CacheControl = "no-cache";
            http.Response.Headers["X-Accel-Buffering"] = "no";   // disable any reverse-proxy buffering
            await http.Response.Body.FlushAsync(ct);

            async Task WriteEventAsync(string evt, object payload)
            {
                var json = JsonSerializer.Serialize(payload, SseJsonOpts);
                await http.Response.WriteAsync($"event: {evt}\n", ct);
                await http.Response.WriteAsync($"data: {json}\n\n", ct);
                await http.Response.Body.FlushAsync(ct);
            }

            try
            {
                var final = await orchestrator.RunAsync(
                    req,
                    onTrace: async t => await WriteEventAsync("trace", t),
                    ct: ct);
                await WriteEventAsync("done", final);
            }
            catch (OperationCanceledException) { /* client disconnected */ }
            catch (Exception ex)
            {
                await WriteEventAsync("error", new { message = ex.Message });
            }
        })
        .WithName("GenerateDesignStream");

        grp.MapGet("/health", () => Results.Ok(new { status = "ok" }))
           .WithName("DesignHealth");

        return app;
    }
}
