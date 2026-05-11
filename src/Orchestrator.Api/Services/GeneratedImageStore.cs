using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using InteriorDesign.Orchestrator.Options;
using Microsoft.Extensions.Options;

namespace InteriorDesign.Orchestrator.Services;

/// <summary>
/// Persists generated bathroom renders to blob storage. The container is created by
/// storage.bicep as a private container - clients fetch the image base64 via the
/// orchestrator API instead of a direct blob URL, so no anonymous access is needed.
/// </summary>
public class GeneratedImageStore
{
    private readonly BlobContainerClient _container;

    public GeneratedImageStore(IOptions<AzureOptions> opts, Azure.Core.TokenCredential credential)
    {
        var o = opts.Value;
        var service = new BlobServiceClient(new Uri(o.BlobAccountUrl), credential);
        _container = service.GetBlobContainerClient(o.GeneratedContainer);
    }

    public virtual async Task<Uri> SaveAsync(byte[] png, string conversationId, CancellationToken ct = default)
    {
        // The container is declared in storage.bicep (private, no public access).
        // We do NOT call CreateIfNotExistsAsync(PublicAccessType.Blob, ...) here:
        // the storage account has allowBlobPublicAccess=false (org-policy enforced),
        // which makes any container-level public-access elevation fail with:
        //   "Public access is not permitted on this storage account."
        // That used to short-circuit every image generation BEFORE the upload even
        // started. If the container is somehow missing (manual delete, fresh RG),
        // we still create it - but with PublicAccessType.None, which is compatible
        // with the account-level flag.
        var name = $"{conversationId}/{DateTimeOffset.UtcNow:yyyyMMddHHmmssfff}.png";
        var blob = _container.GetBlobClient(name);
        var headers = new BlobHttpHeaders { ContentType = "image/png" };

        try
        {
            using var ms = new MemoryStream(png);
            await blob.UploadAsync(ms, headers, cancellationToken: ct);
        }
        catch (Azure.RequestFailedException ex) when (ex.ErrorCode == "ContainerNotFound")
        {
            await _container.CreateIfNotExistsAsync(PublicAccessType.None, cancellationToken: ct);
            using var ms = new MemoryStream(png);
            await blob.UploadAsync(ms, headers, cancellationToken: ct);
        }

        // We hand the bytes back to callers as base64 (BlazorServer renders inline)
        // so this URL is only used for logging / traceability - no anonymous fetch
        // ever happens against it.
        return blob.Uri;
    }
}


