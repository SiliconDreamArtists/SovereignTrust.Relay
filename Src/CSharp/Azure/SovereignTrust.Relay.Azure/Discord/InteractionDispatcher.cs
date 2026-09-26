using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Blobs.Specialized;
using Azure.Storage.Queues;
namespace SovereignTrust.Relay.Azure.Azure.Discord;

public enum DispatchResult { Accepted, Duplicate, Busy }
public interface IInteractionDispatcher { Task<DispatchResult> DispatchAsync(string id, string message, CancellationToken cancellationToken); }
public interface IMessageQueue { Task SendAsync(string message, CancellationToken cancellationToken); }
public interface IReceiptStore { Task<IReceipt?> AcquireAsync(string id, CancellationToken cancellationToken); }
public interface IReceipt : IAsyncDisposable
{
    bool Completed { get; }
    Task CompleteAsync(CancellationToken cancellationToken);
}
public sealed class InteractionDispatcher(IReceiptStore receipts, IMessageQueue queue) : IInteractionDispatcher
{
    public async Task<DispatchResult> DispatchAsync(string id, string message, CancellationToken cancellationToken)
    {
        await using var receipt = await receipts.AcquireAsync(id, cancellationToken);
        if (receipt is null) return DispatchResult.Busy;
        if (receipt.Completed) return DispatchResult.Duplicate;
        await queue.SendAsync(message, cancellationToken);
        // Mark only after confirmed enqueue. Failures remain retryable.
        await receipt.CompleteAsync(cancellationToken);
        return DispatchResult.Accepted;
    }
}
public sealed class AzureMessageQueue(QueueClient queue) : IMessageQueue
{
    public async Task SendAsync(string message, CancellationToken cancellationToken) =>
        await queue.SendMessageAsync(message, cancellationToken);
}
public sealed class BlobReceiptStore(BlobContainerClient container) : IReceiptStore
{
    public async Task<IReceipt?> AcquireAsync(string id, CancellationToken cancellationToken)
    {
        var blob = container.GetBlobClient(id);
        try { await blob.UploadAsync(BinaryData.FromString("pending"), overwrite: false, cancellationToken); }
        catch (RequestFailedException ex) when (ex.ErrorCode is "BlobAlreadyExists" or "LeaseIdMissing") { }
        var lease = blob.GetBlobLeaseClient();
        try { await lease.AcquireAsync(TimeSpan.FromSeconds(15), cancellationToken: cancellationToken); }
        catch (RequestFailedException ex) when (ex.ErrorCode == "LeaseAlreadyPresent") { return null; }
        var receipt = new BlobReceipt(blob, lease);
        try
        {
            var properties = await blob.GetPropertiesAsync(new BlobRequestConditions { LeaseId = lease.LeaseId }, cancellationToken);
            receipt.Completed = properties.Value.Metadata.TryGetValue("state", out var state) && state == "complete";
            return receipt;
        }
        catch { await receipt.DisposeAsync(); throw; }
    }
    private sealed class BlobReceipt(BlobClient blob, BlobLeaseClient lease) : IReceipt
    {
        public bool Completed { get; set; }
        public async Task CompleteAsync(CancellationToken cancellationToken) =>
            await blob.SetMetadataAsync(new Dictionary<string, string> { ["state"] = "complete" },
                new BlobRequestConditions { LeaseId = lease.LeaseId }, cancellationToken);
        public async ValueTask DisposeAsync()
        {
            using var cleanup = new CancellationTokenSource(TimeSpan.FromMilliseconds(150));
            try { await lease.ReleaseAsync(cancellationToken: cleanup.Token); }
            catch (OperationCanceledException) { }
            catch (RequestFailedException) { } // A lost release is recovered by the finite 15-second lease.
        }
    }
}
