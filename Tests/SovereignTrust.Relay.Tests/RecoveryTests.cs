using System.Diagnostics;
using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using SovereignTrust.Relay.Azure.Azure.Discord;
using Xunit;

public sealed class RecoveryTests
{
    [Fact, Trait("Category", "Storage")]
    public async Task StalledLeaseReleaseIsCanceledByCleanupBudget()
    {
        using var http = new HttpClient(new StalledReleaseHandler { InnerHandler = new HttpClientHandler() });
        var options = new BlobClientOptions { Transport = new Azure.Core.Pipeline.HttpClientTransport(http), Retry = { MaxRetries = 0 } };
        var container = new BlobContainerClient("UseDevelopmentStorage=true", "receipts-" + Guid.NewGuid().ToString("N"), options);
        await container.CreateAsync();
        try
        {
            var receipt = await new BlobReceiptStore(container).AcquireAsync("123", default);
            Assert.NotNull(receipt);
            var elapsed = Stopwatch.StartNew();
            await receipt.DisposeAsync();
            Assert.InRange(elapsed.Elapsed.TotalMilliseconds, 100, 1000); //150ms cleanup token plus test-host scheduling tolerance.
            Assert.Null(await new BlobReceiptStore(container).AcquireAsync("123", default));
        }
        finally { await container.DeleteIfExistsAsync(); }
    }

    private sealed class StalledReleaseHandler : DelegatingHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.Headers.TryGetValues("x-ms-lease-action", out var actions) && actions.Contains("release"))
                await Task.Delay(Timeout.Infinite, cancellationToken);
            return await base.SendAsync(request, cancellationToken);
        }
    }

    [Fact]
    public async Task CompletionFailureAndAmbiguousSendRemainAtLeastOnce()
    {
        var store = new Receipts { FailCompletion = true }; var queue = new Queue();
        var dispatcher = new InteractionDispatcher(store, queue);
        await Assert.ThrowsAsync<IOException>(() => dispatcher.DispatchAsync("123", "payload", default));
        Assert.Equal(1, queue.Sends); Assert.False(store.Done);
        store.FailCompletion = false;
        Assert.Equal(DispatchResult.Accepted, await dispatcher.DispatchAsync("123", "payload", default));
        Assert.Equal(2, queue.Sends);
        Assert.Equal(DispatchResult.Duplicate, await dispatcher.DispatchAsync("123", "payload", default));
        var ambiguous = new Queue { Ambiguous = true }; store = new Receipts();
        dispatcher = new(store, ambiguous);
        await Assert.ThrowsAsync<IOException>(() => dispatcher.DispatchAsync("124", "payload", default));
        Assert.Equal(1, ambiguous.Sends); Assert.False(store.Done);
        ambiguous.Ambiguous = false;
        Assert.Equal(DispatchResult.Accepted, await dispatcher.DispatchAsync("124", "payload", default));
        Assert.Equal(2, ambiguous.Sends); // Consumer must deduplicate persistent Result.id.
    }

    [Fact, Trait("Category", "Storage")]
    public async Task ProcessCrashLeaseExpiresAndRestartedHandlerCompletes()
    {
        var name = "receipts-" + Guid.NewGuid().ToString("N");
        var container = new BlobContainerClient("UseDevelopmentStorage=true", name);
        await container.CreateAsync();
        Process? child = null;
        try
        {
            var worker = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../LeaseCrashWorker/bin/Release/net10.0/LeaseCrashWorker.dll"));
            var start = new ProcessStartInfo("dotnet") { UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true, CreateNoWindow = true };
            start.ArgumentList.Add(worker); start.ArgumentList.Add(name); start.ArgumentList.Add("123");
            child = Process.Start(start)!;
            Assert.Equal("acquired", await child.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(15)));
            var store = new BlobReceiptStore(container);
            Assert.Null(await store.AcquireAsync("123", default));
            child.Kill(true); await child.WaitForExitAsync();
            Assert.Null(await store.AcquireAsync("123", default)); // Crash does not clear finite lease.
            await Task.Delay(TimeSpan.FromSeconds(16));
            await using (var recovered = await store.AcquireAsync("123", default))
            {
                Assert.NotNull(recovered); Assert.False(recovered.Completed); await recovered.CompleteAsync(default);
            }
            await using var duplicate = await new BlobReceiptStore(container).AcquireAsync("123", default);
            Assert.NotNull(duplicate); Assert.True(duplicate.Completed);
            var properties = (await container.GetBlobClient("123").GetPropertiesAsync()).Value;
            Assert.Single(properties.Metadata); Assert.Equal("complete", properties.Metadata["state"]);
            Assert.Equal("pending", (await container.GetBlobClient("123").DownloadContentAsync()).Value.Content.ToString());
        }
        finally
        {
            if (child is not null) { if (!child.HasExited) { child.Kill(true); await child.WaitForExitAsync(); } child.Dispose(); }
            await container.DeleteIfExistsAsync();
        }
    }

    [Fact, Trait("Category", "Storage")]
    public async Task ConcurrentIndependentHandlersSendOneConfirmedMessage()
    {
        var suffix = Guid.NewGuid().ToString("N");
        var container = new BlobContainerClient("UseDevelopmentStorage=true", "receipts-" + suffix);
        var queue = new QueueClient("UseDevelopmentStorage=true", "queue-" + suffix,
            new QueueClientOptions { MessageEncoding = QueueMessageEncoding.Base64, Retry = { MaxRetries = 0 } });
        await container.CreateAsync(); await queue.CreateAsync();
        try
        {
            var results = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => new InteractionDispatcher(new BlobReceiptStore(container), new AzureMessageQueue(queue)).DispatchAsync("123", "payload", default)));
            Assert.Single(results, x => x == DispatchResult.Accepted);
            Assert.All(results, value => Assert.Contains(value, new[] { DispatchResult.Accepted, DispatchResult.Busy, DispatchResult.Duplicate }));
            Assert.Single((await queue.ReceiveMessagesAsync(10)).Value);
        }
        finally { await queue.DeleteIfExistsAsync(); await container.DeleteIfExistsAsync(); }
    }

    private sealed class Queue : IMessageQueue
    {
        public int Sends; public bool Ambiguous;
        public Task SendAsync(string message, CancellationToken token) { Sends++; if (Ambiguous) throw new IOException("send response lost"); return Task.CompletedTask; }
    }
    private sealed class Receipts : IReceiptStore
    {
        public bool Done, FailCompletion;
        public Task<IReceipt?> AcquireAsync(string id, CancellationToken token) => Task.FromResult<IReceipt?>(new Receipt(this));
        private sealed class Receipt(Receipts store) : IReceipt
        {
            public bool Completed => store.Done;
            public Task CompleteAsync(CancellationToken token) { if (store.FailCompletion) throw new IOException("completion unavailable"); store.Done = true; return Task.CompletedTask; }
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }
}
