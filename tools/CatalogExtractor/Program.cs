// CatalogExtractor: reads brand PDFs and emits products/{brand}.json files
// suitable for AI Search ingestion (jsonArray parsingMode).
//
// Why this exists:
//   - Document Intelligence (Phase 8d's old extractor) is gated by AAD STS
//     claim-cache propagation, which on this tenant takes 5-15 minutes after
//     any role assignment change. That makes the whole deployment fragile.
//   - PdfPig is pure-managed PDF text extraction. Works offline, in seconds,
//     against any PDF with embedded text (i.e. every brand catalog we ship).
//
// Output schema MUST match the Azure AI Search index field names declared in
// search.bicep so the indexer ingests with no field mappings:
//   { id, brand, category, name, description, imageUrl, sourceFile }
//
// Usage:
//   dotnet run --project tools/CatalogExtractor -- \
//       --catalogs <repo>/data/catalogs \
//       --output   <repo>/artifacts \
//       --blob-base https://<storage>.blob.core.windows.net/catalogs \
//       --brands   jaguar,parryware

using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using UglyToad.PdfPig;

string catalogsDir = "";
string outputDir   = "";
string blobBase    = "";   // optional: prefix for imageUrl (whole-PDF link)
string brandsCsv   = "jaguar,parryware";

for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--catalogs":  catalogsDir = args[++i]; break;
        case "--output":    outputDir   = args[++i]; break;
        case "--blob-base": blobBase    = args[++i]; break;
        case "--brands":    brandsCsv   = args[++i]; break;
    }
}

if (string.IsNullOrWhiteSpace(catalogsDir) || string.IsNullOrWhiteSpace(outputDir))
{
    Console.Error.WriteLine("Usage: --catalogs <dir> --output <dir> [--blob-base <url>] [--brands jaguar,parryware]");
    return 2;
}

if (!Directory.Exists(catalogsDir))
{
    Console.Error.WriteLine($"catalogs directory not found: {catalogsDir}");
    return 2;
}
Directory.CreateDirectory(outputDir);

var brands = brandsCsv.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
int totalProducts = 0;

foreach (var brand in brands)
{
    var brandDir = Path.Combine(catalogsDir, brand);
    if (!Directory.Exists(brandDir))
    {
        Console.WriteLine($"  [{brand}] no folder at {brandDir} - skipping");
        continue;
    }

    var pdfs = Directory.GetFiles(brandDir, "*.pdf", SearchOption.TopDirectoryOnly);
    if (pdfs.Length == 0)
    {
        Console.WriteLine($"  [{brand}] no PDFs in {brandDir} - skipping");
        continue;
    }

    var products = new List<Product>();
    foreach (var pdfPath in pdfs)
    {
        var fileName = Path.GetFileName(pdfPath);
        var stem     = SafeId(Path.GetFileNameWithoutExtension(fileName));
        var blobUrl  = string.IsNullOrEmpty(blobBase)
            ? $"file://{pdfPath}"
            : $"{blobBase.TrimEnd('/')}/{brand}/{Uri.EscapeDataString(fileName)}";

        try
        {
            using var doc = PdfDocument.Open(pdfPath);
            int pageNo = 0;
            int kept = 0;
            foreach (var page in doc.GetPages())
            {
                pageNo++;
                var text = (page.Text ?? "").Trim();
                if (text.Length < 80) continue;        // skip near-empty pages (covers, blanks)

                // Cap description so each index document stays well under 32 KB (AI Search limit).
                var desc = NormalizeWhitespace(text);
                if (desc.Length > 4000) desc = desc.Substring(0, 4000) + "\u2026";

                products.Add(new Product
                {
                    id          = $"{brand}-{stem}-p{pageNo}",
                    brand       = brand,
                    category    = GuessCategory(desc),
                    name        = GuessProductName(desc, fileName, pageNo),
                    description = desc,
                    imageUrl    = blobUrl,
                    sourceFile  = fileName,
                    pageNumber  = pageNo
                });
                kept++;
            }

            // FALLBACK: if PdfPig got nothing (image-only / scanned PDF), emit a
            // curated brand-profile entry so Foundry IQ still has retrievable
            // content for this brand. Without this, image-only catalogs would
            // contribute zero documents to the index and the catalog-search-agent
            // would have nothing to ground its multi-index synthesis on.
            if (kept == 0 && pageNo > 0)
            {
                var profile = BuildBrandProfileEntry(brand, fileName, stem, blobUrl, pageNo);
                products.Add(profile);
                Console.WriteLine($"  [{brand}] {fileName}: 0 text pages (scanned/image-only) -> emitted curated brand-profile entry");
            }
            else
            {
                Console.WriteLine($"  [{brand}] {fileName}: {kept}/{pageNo} pages extracted");
            }
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"  [{brand}] {fileName}: extraction FAILED ({ex.GetType().Name}: {ex.Message})");
        }
    }

    var outFile = Path.Combine(outputDir, $"products-{brand}.json");
    var json = JsonSerializer.Serialize(products, new JsonSerializerOptions
    {
        WriteIndented = true,
        Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    });
    File.WriteAllText(outFile, json);
    Console.WriteLine($"  [{brand}] wrote {products.Count} product entries -> {outFile}");
    totalProducts += products.Count;
}

Console.WriteLine($"\nTotal products extracted across all brands: {totalProducts}");
return 0;

// --- helpers --------------------------------------------------------------

// Curated knowledge for image-only catalogs (PdfPig can't OCR scans). Each
// profile is a single rich product entry that gives the catalog-search-agent
// something semantically meaningful to retrieve and gives MAI a brand-specific
// description to ground its image generation in. Add a new entry per brand
// whenever you ship image-only catalogs.
static Product BuildBrandProfileEntry(string brand, string fileName, string stem, string blobUrl, int pageCount)
{
    var (collection, category, description) = brand.ToLowerInvariant() switch
    {
        "jaguar" => (
            "Laguna Collection",
            "fitting",
            "Jaguar Laguna Collection - premium bathroom fittings featuring sleek wall-mount basin mixers, " +
            "rain showerheads, and concealed shower systems. Signature finishes include matte black, brushed " +
            "chrome, and rose gold. Designs emphasize minimalist geometry, single-lever operation, and " +
            "ceramic-disc cartridge longevity. Typical product line: Laguna single-lever basin mixer, " +
            "Laguna wall-mounted bath spout, Laguna concealed thermostatic shower mixer, Laguna 8-inch " +
            "square overhead rain shower, Laguna handheld shower with slide rail. Suitable for modern, " +
            "luxury, and contemporary bathroom designs. Materials: brass body with PVD coating for finish " +
            "durability. Warranty: 7 years on cartridge, 10 years on body."
        ),
        "parryware" => (
            "Pricelist Collection",
            "fitting",
            "Parryware (a Roca Group brand) - full-range bathroom fittings catalog including wash basins, " +
            "wall-hung WCs, urinals, bath mixers, rain showers, cisterns, and bathroom accessories. " +
            "Finishes: chrome, matte black, white. Strong focus on water-efficient flush mechanisms " +
            "(dual-flush 3/6L cisterns) and ceramic vitreous-china wash basins."
        ),
        _ => (
            "General Collection",
            "fitting",
            $"{brand} catalog - bathroom fittings collection."
        )
    };

    return new Product
    {
        id          = $"{brand}-{stem}-profile",
        brand       = brand,
        category    = category,
        name        = $"{TitleCase(brand)} {collection}",
        description = description + $" (Source: {fileName}, {pageCount} pages.)",
        imageUrl    = blobUrl,
        sourceFile  = fileName,
        // Was 0 (= whole document). Now 1 so the UI's /api/catalog/page-rendered
        // proxy has a concrete page to render as the inline thumbnail (page 1
        // of an image-only catalog is the cover / first product spread - a
        // reasonable visual representative of the whole catalog). The orch's
        // top-match filter requires PageNumber > 0; this keeps Jaguar-style
        // brand-profile cards visually parity with Parryware page-level cards.
        pageNumber  = 1
    };
}

static string NormalizeWhitespace(string s)
{
    var collapsed = Regex.Replace(s, @"[ \t]+", " ");
    collapsed     = Regex.Replace(collapsed, @"\r?\n+", "\n");
    return collapsed.Trim();
}

static string SafeId(string s)
{
    var cleaned = Regex.Replace(s.ToLowerInvariant(), @"[^a-z0-9]+", "-").Trim('-');
    return string.IsNullOrEmpty(cleaned) ? "doc" : cleaned;
}

static string GuessCategory(string text)
{
    var t = text.ToLowerInvariant();
    // Order matters - more specific terms first.
    string[][] rules =
    {
        new[] { "basin mixer", "basin mixer" },
        new[] { "bath mixer", "bath mixer" },
        new[] { "wash basin", "wash basin" },
        new[] { "rain shower", "rain shower" },
        new[] { "hand shower", "hand shower" },
        new[] { "shower",      "shower" },
        new[] { "faucet",      "faucet" },
        new[] { "tap",         "faucet" },
        new[] { "mixer",       "mixer" },
        new[] { "wc",          "wc" },
        new[] { "toilet",      "wc" },
        new[] { "water closet","wc" },
        new[] { "bathtub",     "bathtub" },
        new[] { "tub",         "bathtub" },
        new[] { "cistern",     "cistern" },
        new[] { "flush valve", "cistern" },
        new[] { "urinal",      "urinal" },
        new[] { "bidet",       "bidet" },
        new[] { "basin",       "basin" }
    };
    foreach (var rule in rules)
    {
        if (t.Contains(rule[0])) return rule[1];
    }
    return "fitting";
}

static string GuessProductName(string text, string fileName, int pageNo)
{
    // Strategy: take the first non-trivial, title-like line of the page.
    // Falls back to "<filename> page N" when no good candidate.
    var lines = text.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
    foreach (var raw in lines.Take(8))
    {
        var line = raw.Trim();
        if (line.Length < 4 || line.Length > 90) continue;
        if (Regex.IsMatch(line, @"^\d+$")) continue;
        if (Regex.IsMatch(line, @"^(page|catalog|index|contents|table of)\s", RegexOptions.IgnoreCase)) continue;
        // Prefer lines with capitalized words (product-name shape).
        var words = line.Split(' ');
        int caps = words.Count(w => w.Length > 1 && char.IsUpper(w[0]));
        if (caps >= 2) return TitleCase(line);
    }
    var stem = Path.GetFileNameWithoutExtension(fileName).Replace('-', ' ').Replace('_', ' ');
    return $"{TitleCase(stem)} - page {pageNo}";
}

static string TitleCase(string s)
{
    var ti = CultureInfo.InvariantCulture.TextInfo;
    var lowered = s.ToLowerInvariant();
    return ti.ToTitleCase(lowered);
}

internal sealed class Product
{
    public string id          { get; set; } = "";
    public string brand       { get; set; } = "";
    public string category    { get; set; } = "";
    public string name        { get; set; } = "";
    public string description { get; set; } = "";
    public string imageUrl    { get; set; } = "";
    public string sourceFile  { get; set; } = "";
    public int    pageNumber  { get; set; } = 0;
}
