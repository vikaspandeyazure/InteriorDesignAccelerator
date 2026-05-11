using Azure.Storage.Blobs;
using InteriorDesign.Orchestrator.Options;
using Microsoft.Extensions.Options;
using UglyToad.PdfPig;
using UglyToad.PdfPig.Content;

namespace InteriorDesign.Orchestrator.Services;

/// <summary>
/// Pulls the LARGEST embedded raster image (the "hero" product image) out of a
/// specific page of a brand catalog PDF in private blob storage.
///
/// Why:
///   * AI Search retrieved a page based on its OCR text, but the visual product
///     identity (e.g. Glide Shower Panel C867B99 - tall vertical column with
///     gold accent stripe and hand shower attachment) lives ONLY in the page's
///     images. The compose / image-gen agents never see those visuals from text
///     alone, so MAI ends up generating a generic "matte black rain shower" that
///     bears no resemblance to the cited reference.
///   * This service fetches the page, enumerates its raster XObjects with PdfPig,
///     and returns the largest one. The orchestrator then sends that image into
///     a vision-enabled chat call (gpt-4.1-mini) to get a precise visual
///     description, which is folded into the compose prompt as a "VERIFIED
///     VISUAL REFERENCE". MAI then has something concrete to mimic.
///
/// Returns the raw image bytes + media type (image/jpeg or image/png), or null
/// if the page has no embedded raster (e.g. text-only pricelist tables).
/// </summary>
public interface ICatalogPageImageExtractor
{
    Task<CatalogPageImageExtractor.HeroResult> TryGetHeroAsync(string brand, string sourceFile, int pageNumber, CancellationToken ct = default);

    /// <summary>
    /// Renders the FULL cited PDF page as a PNG. Different from TryGetHeroAsync
    /// which returns just the largest embedded raster on the page - this gives
    /// you the WHOLE page (heading, body copy, product photo, page chrome)
    /// composited in its real catalog layout, suitable for showing as a
    /// thumbnail of "the cited reference" in the UI.
    /// </summary>
    Task<CatalogPageImageExtractor.RenderResult> TryRenderPageAsync(string brand, string sourceFile, int pageNumber, int maxWidthPx, CancellationToken ct = default);
}

public sealed class CatalogPageImageExtractor : ICatalogPageImageExtractor
{
    private readonly IOptions<AzureOptions> _opts;
    private readonly Azure.Core.TokenCredential _credential;
    private readonly ILogger<CatalogPageImageExtractor> _log;

    public CatalogPageImageExtractor(IOptions<AzureOptions> opts, Azure.Core.TokenCredential credential, ILogger<CatalogPageImageExtractor> log)
    {
        _opts = opts;
        _credential = credential;
        _log = log;
    }

    public sealed record HeroImage(byte[] Bytes, string MediaType, int WidthPx, int HeightPx);

    /// <summary>
    /// Result of attempting to pull a hero image. Always carries a status so
    /// the orchestrator can surface a precise diagnostic in the live trace.
    /// </summary>
    public sealed record HeroResult(HeroStatus Status, HeroImage? Image, string Detail)
    {
        public bool Ok => Status == HeroStatus.Ok && Image is not null;
        public static HeroResult Failure(HeroStatus s, string detail) => new(s, null, detail);
    }

    /// <summary>
    /// Result of rendering a FULL PDF page to a raster image (PNG via PDFium).
    /// Bytes carry the encoded image when Ok; null otherwise.
    /// </summary>
    public sealed record RenderResult(HeroStatus Status, byte[]? Bytes, string MediaType, int WidthPx, int HeightPx, string Detail)
    {
        public bool Ok => Status == HeroStatus.Ok && Bytes is { Length: > 0 };
        public static RenderResult Failure(HeroStatus s, string detail) => new(s, null, string.Empty, 0, 0, detail);
    }

    public enum HeroStatus
    {
        Ok,
        InvalidArgs,
        NotConfigured,
        BlobDownloadFailed,
        PdfOpenFailed,
        PageOutOfRange,
        NoImagesOnPage,
        ImageDecodeFailed
    }

    public async Task<HeroResult> TryGetHeroAsync(string brand, string sourceFile, int pageNumber, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(brand) || string.IsNullOrWhiteSpace(sourceFile) || pageNumber < 1)
            return HeroResult.Failure(HeroStatus.InvalidArgs, $"brand='{brand}' file='{sourceFile}' page={pageNumber}");

        var (pdfBytes, dlStatus, dlDetail) = await TryDownloadPdfAsync(brand, sourceFile, ct);
        if (pdfBytes is null)
            return HeroResult.Failure(dlStatus, dlDetail);

        // ---- enumerate the page's raster images, pick the largest
        // (Synchronous helper - PdfPig's IPdfImage exposes ReadOnlySpan<byte>
        // accessors that cannot be used inside an async method on C# 12.)
        return ExtractHeroFromPdf(pdfBytes, pageNumber);
    }

    /// <summary>
    /// Renders the requested PDF page to a PNG using PDFium (via PDFtoImage +
    /// SkiaSharp). Output is downsized to <paramref name="maxWidthPx"/> while
    /// preserving the page's aspect ratio - keeping thumbnails snappy and
    /// the orchestrator's CPU usage bounded for typical catalog pages.
    /// </summary>
    public async Task<RenderResult> TryRenderPageAsync(string brand, string sourceFile, int pageNumber, int maxWidthPx, CancellationToken ct = default)
    {
        if (string.IsNullOrWhiteSpace(brand) || string.IsNullOrWhiteSpace(sourceFile) || pageNumber < 1)
            return RenderResult.Failure(HeroStatus.InvalidArgs, $"brand='{brand}' file='{sourceFile}' page={pageNumber}");
        if (maxWidthPx < 200) maxWidthPx = 200;
        if (maxWidthPx > 2000) maxWidthPx = 2000;

        var (pdfBytes, dlStatus, dlDetail) = await TryDownloadPdfAsync(brand, sourceFile, ct);
        if (pdfBytes is null)
            return RenderResult.Failure(dlStatus, dlDetail);

        return RenderPdfPageToPng(pdfBytes, pageNumber, maxWidthPx);
    }

    /// <summary>
    /// Shared blob fetch used by both TryGetHeroAsync and TryRenderPageAsync.
    /// Returns (bytes, Ok, "") on success; (null, status, detail) on failure.
    /// </summary>
    private async Task<(byte[]? bytes, HeroStatus status, string detail)> TryDownloadPdfAsync(string brand, string sourceFile, CancellationToken ct)
    {
        var o = _opts.Value;
        if (string.IsNullOrWhiteSpace(o.BlobAccountUrl) || string.IsNullOrWhiteSpace(o.CatalogContainer))
            return (null, HeroStatus.NotConfigured, "Azure:BlobAccountUrl / CatalogContainer not set");

        var blobUri = new Uri($"{o.BlobAccountUrl.TrimEnd('/')}/{o.CatalogContainer}/{brand}/{Uri.EscapeDataString(sourceFile)}");
        try
        {
            var blob = new BlobClient(blobUri, _credential);
            using var ms = new MemoryStream();
            await blob.DownloadToAsync(ms, ct);
            return (ms.ToArray(), HeroStatus.Ok, string.Empty);
        }
        catch (Azure.RequestFailedException ex)
        {
            _log.LogWarning(ex, "Blob download HTTP {Status} for {Uri}", ex.Status, blobUri);
            return (null, HeroStatus.BlobDownloadFailed, $"HTTP {ex.Status} {ex.ErrorCode} on {blobUri.AbsolutePath}");
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Blob download exception for {Uri}", blobUri);
            return (null, HeroStatus.BlobDownloadFailed, $"{ex.GetType().Name}: {ex.Message} on {blobUri.AbsolutePath}");
        }
    }

    private RenderResult RenderPdfPageToPng(byte[] pdfBytes, int pageNumber, int maxWidthPx)
    {
        try
        {
            // PDFtoImage indexes pages 0-based, ours is 1-based.
            // The library streams via PDFium native + SkiaSharp - on Linux it
            // needs libfontconfig1 (installed by the Dockerfile).
            using var skBitmap = PDFtoImage.Conversion.ToImage(
                pdfBytes,
                page: pageNumber - 1,
                options: new PDFtoImage.RenderOptions(
                    Dpi: 0,
                    Width: maxWidthPx,
                    Height: null,
                    WithAnnotations: true,
                    WithFormFill: false,
                    WithAspectRatio: true,
                    BackgroundColor: SkiaSharp.SKColors.White));
            using var data = skBitmap.Encode(SkiaSharp.SKEncodedImageFormat.Png, 85);
            return new RenderResult(HeroStatus.Ok, data.ToArray(), "image/png", skBitmap.Width, skBitmap.Height, $"rendered page {pageNumber} @ {skBitmap.Width}x{skBitmap.Height}");
        }
        catch (ArgumentOutOfRangeException ex)
        {
            return RenderResult.Failure(HeroStatus.PageOutOfRange, $"page {pageNumber}: {ex.Message}");
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "PDFium render failed on page {Page} of {Bytes} byte PDF", pageNumber, pdfBytes.Length);
            return RenderResult.Failure(HeroStatus.PdfOpenFailed, $"{ex.GetType().Name}: {ex.Message}");
        }
    }

    private HeroResult ExtractHeroFromPdf(byte[] pdfBytes, int pageNumber)
    {
        UglyToad.PdfPig.PdfDocument doc;
        try
        {
            doc = PdfDocument.Open(pdfBytes);
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "PdfPig open failed ({Bytes} bytes)", pdfBytes.Length);
            return HeroResult.Failure(HeroStatus.PdfOpenFailed, $"{ex.GetType().Name}: {ex.Message} ({pdfBytes.Length} bytes)");
        }
        try
        {
            if (pageNumber > doc.NumberOfPages)
                return HeroResult.Failure(HeroStatus.PageOutOfRange, $"page {pageNumber} > total {doc.NumberOfPages}");

            var page = doc.GetPage(pageNumber);
            IPdfImage? best = null;
            long bestArea = 0;
            int total = 0;
            foreach (var img in page.GetImages())
            {
                total++;
                long area = (long)img.WidthInSamples * img.HeightInSamples;
                if (area > bestArea)
                {
                    best = img;
                    bestArea = area;
                }
            }
            if (best is null)
                return HeroResult.Failure(HeroStatus.NoImagesOnPage, $"page {pageNumber} has 0 raster images");

            // Build the candidate byte arrays in priority order. PdfPig's
            // accessors are inconsistent across image streams: some images
            // expose TryGetBytesAsMemory, others only RawBytes, others need
            // TryGetPng to materialise. We collect what we can, then PICK by
            // sniffing magic bytes - that way we always tag the right MIME
            // type instead of mislabelling a JPEG as application/octet-stream
            // (the bug that broke the inline hero thumbnail).
            byte[]? candidate = null;
            if (best.TryGetBytesAsMemory(out var encodedMem))
            {
                candidate = encodedMem.ToArray();
            }
            if (candidate is null || candidate.Length == 0)
            {
                var raw = best.RawBytes;
                if (raw.Length > 0) candidate = raw.ToArray();
            }

            if (candidate is { Length: > 3 })
            {
                if (IsJpeg(candidate))
                {
                    return new HeroResult(HeroStatus.Ok,
                        new HeroImage(candidate, "image/jpeg", best.WidthInSamples, best.HeightInSamples),
                        $"page {pageNumber}: {total} imgs, hero {best.WidthInSamples}x{best.HeightInSamples} JPEG ({candidate.Length / 1024}KB)");
                }
                if (IsPng(candidate))
                {
                    return new HeroResult(HeroStatus.Ok,
                        new HeroImage(candidate, "image/png", best.WidthInSamples, best.HeightInSamples),
                        $"page {pageNumber}: {total} imgs, hero {best.WidthInSamples}x{best.HeightInSamples} PNG ({candidate.Length / 1024}KB)");
                }
            }

            // Last resort: ask PdfPig to re-encode as PNG (works for any
            // decodable image, but allocates a fresh buffer + may be slower
            // than streaming the original encoded bytes).
            if (best.TryGetPng(out var png) && png is not null)
            {
                return new HeroResult(HeroStatus.Ok,
                    new HeroImage(png, "image/png", best.WidthInSamples, best.HeightInSamples),
                    $"page {pageNumber}: {total} imgs, hero {best.WidthInSamples}x{best.HeightInSamples} PNG re-encode ({png.Length / 1024}KB)");
            }

            return HeroResult.Failure(HeroStatus.ImageDecodeFailed, $"page {pageNumber} hero {best.WidthInSamples}x{best.HeightInSamples} - no decoder produced bytes");
        }
        finally
        {
            doc.Dispose();
        }
    }

    public static string ToDataUrl(HeroImage img)
        => $"data:{img.MediaType};base64,{Convert.ToBase64String(img.Bytes)}";

    private static bool IsJpeg(byte[] bytes)
        => bytes.Length > 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF;

    private static bool IsPng(byte[] bytes)
        => bytes.Length > 8
            && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
            && bytes[4] == 0x0D && bytes[5] == 0x0A && bytes[6] == 0x1A && bytes[7] == 0x0A;
}
