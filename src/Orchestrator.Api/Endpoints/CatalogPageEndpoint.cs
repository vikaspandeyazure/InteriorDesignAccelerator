using Azure.Storage.Blobs;
using InteriorDesign.Orchestrator.Options;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Options;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Writer;

namespace InteriorDesign.Orchestrator.Endpoints;

/// <summary>
/// Authenticated proxy that serves a SINGLE PAGE from a brand catalog PDF.
///
/// Why this exists:
///   * Storage account has allowBlobPublicAccess=false (org-policy enforced),
///     so the UI cannot link directly to https://.../catalogs/parryware/X.pdf.
///   * Even if it could, opening the WHOLE PDF for a search hit on page 8 is
///     a poor experience.
///   * This endpoint authenticates with the orchestrator's MI to fetch the
///     source PDF from blob, extracts ONLY the requested page using PdfPig,
///     and streams it back inline as application/pdf.
///
/// Routes:
///   GET /api/catalog/page?brand=parryware&amp;file=Parryware_Pricelist...pdf&amp;page=8
///       -> returns a 1-page PDF containing only page 8 of the source.
///   GET /api/catalog/page?brand=jaguar&amp;file=LAGUNA-CATALOG.pdf
///       -> page omitted (or 0) returns the WHOLE source PDF (used by
///          brand-profile entries that don't map to a single page).
/// </summary>
public static class CatalogPageEndpoint
{
    public static IEndpointRouteBuilder MapCatalogPageEndpoint(this IEndpointRouteBuilder app)
    {
        // ---- /api/catalog/page-image ------------------------------------
        // Returns the LARGEST embedded raster image (the "hero" product photo)
        // from a specific page of a brand catalog PDF. Used by the UI's
        // ProductCard component to render the actual catalog product image
        // inline, right next to the MAI render and the "USED BY MAI" badge -
        // so the designer can SEE the source of truth that fed the visual
        // grounding step. No anonymous access; the orchestrator's MI fetches
        // the source PDF from private blob storage.
        app.MapGet("/api/catalog/page-image", async (
            string brand,
            string file,
            int page,
            Services.ICatalogPageImageExtractor extractor,
            HttpContext http,
            CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(brand) || string.IsNullOrWhiteSpace(file) || page < 1)
                return Results.BadRequest(new { error = "brand, file, and page (>=1) are required" });

            var allowedBrands = new[] { "jaguar", "parryware" };
            if (!allowedBrands.Contains(brand, StringComparer.OrdinalIgnoreCase))
                return Results.BadRequest(new { error = $"unknown brand '{brand}'" });
            if (file.Contains("..") || file.Contains('/') || file.Contains('\\'))
                return Results.BadRequest(new { error = "invalid file name" });

            var hero = await extractor.TryGetHeroAsync(brand, file, page, ct);
            if (!hero.Ok)
            {
                return Results.NotFound(new { error = $"no hero image: {hero.Status} - {hero.Detail}" });
            }
            // 7 days cache - source PDFs are immutable in this demo.
            http.Response.Headers.CacheControl = "public, max-age=604800, immutable";
            return Results.File(hero.Image!.Bytes, hero.Image.MediaType);
        })
        .WithName("GetCatalogPageImage")
        .WithTags("Catalog");

        // ---- /api/catalog/page-rendered ---------------------------------
        // Returns the FULL PDF page rendered as a PNG. Unlike /page-image
        // (which extracts just the largest embedded raster), this renders
        // the page through PDFium (PDFtoImage + SkiaSharp) so the response
        // shows the actual page layout: heading + body copy + product photo
        // + page chrome - exactly as it appears in the source catalog. Used
        // by the "Fittings you may like" cards as a "see the cited page"
        // thumbnail. Optional `width` query (default 900, capped 200..2000)
        // controls the output width; aspect ratio is preserved.
        app.MapGet("/api/catalog/page-rendered", async (
            string brand,
            string file,
            int page,
            int? width,
            Services.ICatalogPageImageExtractor extractor,
            HttpContext http,
            CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(brand) || string.IsNullOrWhiteSpace(file) || page < 1)
                return Results.BadRequest(new { error = "brand, file, and page (>=1) are required" });

            var allowedBrands = new[] { "jaguar", "parryware" };
            if (!allowedBrands.Contains(brand, StringComparer.OrdinalIgnoreCase))
                return Results.BadRequest(new { error = $"unknown brand '{brand}'" });
            if (file.Contains("..") || file.Contains('/') || file.Contains('\\'))
                return Results.BadRequest(new { error = "invalid file name" });

            var rendered = await extractor.TryRenderPageAsync(brand, file, page, width ?? 900, ct);
            if (!rendered.Ok)
            {
                return Results.NotFound(new { error = $"render failed: {rendered.Status} - {rendered.Detail}" });
            }
            http.Response.Headers.CacheControl = "public, max-age=604800, immutable";
            return Results.File(rendered.Bytes!, rendered.MediaType);
        })
        .WithName("GetCatalogPageRendered")
        .WithTags("Catalog");

        // ---- /api/catalog/page ------------------------------------------
        app.MapGet("/api/catalog/page", async (
            string brand,
            string file,
            int? page,
            IOptions<AzureOptions> opts,
            Azure.Core.TokenCredential cred,
            HttpContext http,
            CancellationToken ct) =>
        {
            // ---- input validation (defense in depth - we never trust query strings)
            if (string.IsNullOrWhiteSpace(brand) || string.IsNullOrWhiteSpace(file))
                return Results.BadRequest(new { error = "brand and file query parameters are required" });

            // brand must be a known catalog folder; file must not contain path traversal.
            var allowedBrands = new[] { "jaguar", "parryware" };
            if (!allowedBrands.Contains(brand, StringComparer.OrdinalIgnoreCase))
                return Results.BadRequest(new { error = $"unknown brand '{brand}'" });
            if (file.Contains("..") || file.Contains('/') || file.Contains('\\'))
                return Results.BadRequest(new { error = "invalid file name" });

            var o = opts.Value;
            if (string.IsNullOrWhiteSpace(o.BlobAccountUrl) || string.IsNullOrWhiteSpace(o.CatalogContainer))
                return Results.Problem("Catalog blob storage is not configured.");

            // ---- fetch source PDF from private blob via MI
            var blobUri = new Uri($"{o.BlobAccountUrl.TrimEnd('/')}/{o.CatalogContainer}/{brand}/{Uri.EscapeDataString(file)}");
            var blob = new BlobClient(blobUri, cred);
            byte[] sourceBytes;
            try
            {
                using var ms = new MemoryStream();
                await blob.DownloadToAsync(ms, ct);
                sourceBytes = ms.ToArray();
            }
            catch (Azure.RequestFailedException ex) when (ex.Status == 404)
            {
                return Results.NotFound(new { error = $"catalog blob not found: {brand}/{file}" });
            }

            // ---- whole-PDF fast path (page == 0 or missing)
            if (page is null or <= 0)
            {
                http.Response.Headers["Content-Disposition"] = BuildContentDisposition(file);
                return Results.File(sourceBytes, "application/pdf");
            }

            // ---- single-page extract path
            byte[] singlePagePdf;
            try
            {
                using var src = PdfDocument.Open(sourceBytes);
                if (page.Value < 1 || page.Value > src.NumberOfPages)
                {
                    return Results.BadRequest(new { error = $"page {page} out of range (1..{src.NumberOfPages})" });
                }
                var builder = new PdfDocumentBuilder();
                builder.AddPage(src, page.Value);
                singlePagePdf = builder.Build();
            }
            catch (Exception ex)
            {
                return Results.Problem($"PDF extract failed: {ex.GetType().Name}: {ex.Message}");
            }

            var stem = Path.GetFileNameWithoutExtension(file);
            var outName = $"{stem}-page-{page}.pdf";
            http.Response.Headers["Content-Disposition"] = BuildContentDisposition(outName);
            // 1 day cache - source PDFs are immutable in this demo.
            http.Response.Headers.CacheControl = "public, max-age=86400";
            return Results.File(singlePagePdf, "application/pdf");
        })
        .WithName("GetCatalogPage")
        .WithTags("Catalog");

        return app;
    }

    /// <summary>
    /// Builds an RFC-5987 / RFC-6266 compatible Content-Disposition value that
    /// works for filenames containing non-ASCII characters (em-dash, non-Latin
    /// scripts, etc). Without this, Kestrel rejects the header with
    /// `InvalidOperationException: Invalid non-ASCII or control character in header`
    /// the moment a request hits a Parryware file (filenames contain `\u2013`).
    /// We send BOTH the legacy ASCII `filename=` (with non-ASCII stripped) and
    /// the modern UTF-8 `filename*=` so all browsers display the right name.
    /// </summary>
    private static string BuildContentDisposition(string fileName)
    {
        // Strip / replace non-ASCII for the legacy field.
        var ascii = new string(fileName.Select(c => c < 0x20 || c > 0x7E ? '_' : c).ToArray());
        var utf8  = Uri.EscapeDataString(fileName);
        return $"inline; filename=\"{ascii}\"; filename*=UTF-8''{utf8}";
    }
}
