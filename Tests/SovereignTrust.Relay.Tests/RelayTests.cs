using System.Globalization;
using System.Reflection;
using System.Text;
using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using NSec.Cryptography;
using SovereignTrust.Relay.Azure;
using SovereignTrust.Relay.Azure.Azure;
using SovereignTrust.Relay.Azure.Azure.Discord;
using Xunit;

public sealed class RelayTests : IDisposable
{
    private readonly Key key = Key.Create(SignatureAlgorithm.Ed25519,
        new KeyCreationParameters { ExportPolicy = KeyExportPolicies.AllowPlaintextExport });
    private readonly TimeProvider clock = new FixedClock();
    private string PublicKeyHex => Convert.ToHexString(key.PublicKey.Export(KeyBlobFormat.RawPublicKey));
    private RelaySettings Settings(bool enabled = false) => new(PublicKeyHex, "UseDevelopmentStorage=true",
        "discord-interactions", "discord-receipts", enabled,
        enabled ? Convert.ToHexString(key.Export(KeyBlobFormat.RawPrivateKey)) : null);
    public RelayTests() => SignalGraph.Signal.Logger = NullLogger.Instance;
    public void Dispose() => key.Dispose();

    private HttpRequest Request(string body, long? seconds = null)
    {
        var req = new DefaultHttpContext().Request;
        req.Body = new MemoryStream(Encoding.UTF8.GetBytes(body));
        var stamp = (seconds ?? clock.GetUtcNow().ToUnixTimeSeconds()).ToString(CultureInfo.InvariantCulture);
        req.Headers["X-Signature-Timestamp"] = stamp;
        req.Headers["X-Signature-Ed25519"] = Convert.ToHexString(
            SignatureAlgorithm.Ed25519.Sign(key, Encoding.UTF8.GetBytes(stamp + body)));
        return req;
    }
    private DiscordRelay Relay(IInteractionDispatcher dispatcher) =>
        new(NullLogger<DiscordRelay>.Instance, Settings(), dispatcher, clock);

    [Theory]
    [InlineData(null)]
    [InlineData("false")]
    [InlineData("invalid")]
    public void SigningDefaultsOff(string? value)
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string,string?>
        {
            ["DISCORD_PUBLIC_KEY"] = PublicKeyHex, ["StorageQueueAccount"] = "UseDevelopmentStorage=true",
            ["ENABLE_ED25519_SIGNING"] = value
        }).Build();
        Assert.False(RelaySettings.Load(config).SigningEnabled);
    }

    [Theory]
    [InlineData("DISCORD_PUBLIC_KEY", null)]
    [InlineData("DISCORD_PUBLIC_KEY", "bad")]
    [InlineData("StorageQueueAccount", null)]
    [InlineData("StorageQueueAccount", "bad")]
    [InlineData("DISCORD_QUEUE_NAME", "Bad--Name")]
    [InlineData("DISCORD_DEDUP_CONTAINER", "Bad")]
    public void InvalidConfigurationFails(string name, string? value)
    {
        var values = new Dictionary<string,string?>
        { ["DISCORD_PUBLIC_KEY"] = PublicKeyHex, ["StorageQueueAccount"] = "UseDevelopmentStorage=true" };
        values[name] = value;
        Assert.Throws<InvalidOperationException>(() => RelaySettings.Load(
            new ConfigurationBuilder().AddInMemoryCollection(values).Build()));
    }

    [Fact]
    public void EnabledHelperRequiresTestKey()
    {
        var values = new Dictionary<string,string?>
        { ["DISCORD_PUBLIC_KEY"] = PublicKeyHex, ["StorageQueueAccount"] = "UseDevelopmentStorage=true",
          ["ENABLE_ED25519_SIGNING"] = "true" };
        Assert.Throws<InvalidOperationException>(() => RelaySettings.Load(
            new ConfigurationBuilder().AddInMemoryCollection(values).Build()));
    }

    [Fact]
    public async Task DisabledSigningReturns404()
    {
        Assert.IsType<NotFoundResult>(await new Ed25519SignFunction(Settings(), clock).Run(Request("test")));
    }

    [Fact]
    public async Task SigningReturnsValidSignatureWithoutPrivateKey()
    {
        var response = Assert.IsType<JsonResult>(await new Ed25519SignFunction(Settings(true), clock).Run(Request("test")));
        var json = JObject.FromObject(response.Value!);
        Assert.Null(json["privateKey"]);
        Assert.DoesNotContain(Settings(true).TestPrivateKey!, json.ToString(), StringComparison.OrdinalIgnoreCase);
        Assert.True(SignatureAlgorithm.Ed25519.Verify(key.PublicKey,
            Encoding.UTF8.GetBytes(json.Value<string>("timestamp") + "test"),
            Convert.FromHexString(json.Value<string>("signature")!)));
        var trigger = typeof(Ed25519SignFunction).GetMethod("Run")!.GetParameters()[0]
            .GetCustomAttribute<HttpTriggerAttribute>();
        Assert.Equal(AuthorizationLevel.Function, trigger!.AuthLevel);
    }

    [Fact]
    public void DisabledKeyGenerationReturns404() =>
        Assert.IsType<NotFoundResult>(new Ed25519KeyGenerator(
            NullLogger<Ed25519KeyGenerator>.Instance, Settings()).Run(Request("")));

    [Fact]
    public async Task PingDoesNotAccessStorage()
    {
        var dispatcher = new StubDispatcher { Throw = true };
        var response = Assert.IsType<JsonResult>(await Relay(dispatcher).RunDiscordRelayAsync(Request("{\"type\":1}")));
        Assert.Equal(1, JObject.FromObject(response.Value!).Value<int>("type"));
        Assert.Equal(0, dispatcher.Calls);
    }

    [Theory]
    [InlineData(-301)]
    [InlineData(31)]
    public async Task StaleOrFutureSignatureRejected(int offset)
    {
        Assert.IsType<UnauthorizedResult>(await Relay(new StubDispatcher()).RunDiscordRelayAsync(
            Request("{\"type\":1}", clock.GetUtcNow().ToUnixTimeSeconds() + offset)));
    }

    [Fact]
    public async Task TamperedSignatureRejected()
    {
        var req = Request("{\"type\":1}");
        req.Headers["X-Signature-Ed25519"] = new string('0', 128);
        Assert.IsType<UnauthorizedResult>(await Relay(new StubDispatcher()).RunDiscordRelayAsync(req));
    }

    [Theory]
    [InlineData("not-json")]
    [InlineData("{\"type\":4,\"id\":\"123\"}")]
    [InlineData("{\"type\":2}")]
    [InlineData("{\"type\":\"2\",\"id\":\"123\"}")]
    public async Task InvalidPayloadNeverEnqueued(string body)
    {
        var dispatcher = new StubDispatcher();
        Assert.IsType<BadRequestObjectResult>(await Relay(dispatcher).RunDiscordRelayAsync(Request(body)));
        Assert.Equal(0, dispatcher.Calls);
    }

    [Fact]
    public async Task AcceptedInteractionPreservesIdAndDefers()
    {
        var dispatcher = new StubDispatcher();
        var response = Assert.IsType<JsonResult>(await Relay(dispatcher).RunDiscordRelayAsync(
            Request("{\"type\":2,\"id\":\"123\"}")));
        Assert.Equal(5, JObject.FromObject(response.Value!).Value<int>("type"));
        Assert.Equal("123", JObject.Parse(dispatcher.Message!)["Result"]!.Value<string>("id"));
    }

    [Fact]
    public async Task StorageFailureReturns503()
    {
        var result = await Relay(new StubDispatcher { Throw = true }).RunDiscordRelayAsync(
            Request("{\"type\":2,\"id\":\"123\"}"));
        Assert.Equal(503, Assert.IsType<StatusCodeResult>(result).StatusCode);
    }

    [Fact]
    public async Task StorageWorkIsCanceledAtDeadline()
    {
        var result = await Relay(new StubDispatcher { Wait = true }).RunDiscordRelayAsync(
            Request("{\"type\":2,\"id\":\"123\"}"));
        Assert.Equal(503, Assert.IsType<StatusCodeResult>(result).StatusCode);
    }

    [Fact]
    public async Task DuplicateAndFailedEnqueueBehavior()
    {
        var receipts = new MemoryReceipts();
        var queue = new MemoryQueue { Fail = true };
        var dispatcher = new InteractionDispatcher(receipts, queue);
        await Assert.ThrowsAsync<IOException>(() => dispatcher.DispatchAsync("123", "message", default));
        Assert.False(receipts.Done);
        queue.Fail = false;
        Assert.Equal(DispatchResult.Accepted, await dispatcher.DispatchAsync("123", "message", default));
        Assert.Equal(DispatchResult.Duplicate, await dispatcher.DispatchAsync("123", "message", default));
        Assert.Equal(1, queue.Count);
    }

    [Fact]
    public async Task BusyReceiptDoesNotEnqueue()
    {
        var queue = new MemoryQueue();
        Assert.Equal(DispatchResult.Busy, await new InteractionDispatcher(
            new MemoryReceipts { Busy = true }, queue).DispatchAsync("123", "message", default));
        Assert.Equal(0, queue.Count);
    }

    private sealed class FixedClock : TimeProvider
    { public override DateTimeOffset GetUtcNow() => DateTimeOffset.FromUnixTimeSeconds(1800000000); }
    private sealed class StubDispatcher : IInteractionDispatcher
    {
        public bool Throw, Wait;
        public int Calls;
        public string? Message;
        public async Task<DispatchResult> DispatchAsync(string id, string message, CancellationToken token)
        {
            Calls++; Message = message;
            if (Throw) throw new IOException("storage unavailable");
            if (Wait) await Task.Delay(Timeout.Infinite, token);
            return DispatchResult.Accepted;
        }
    }
    private sealed class MemoryQueue : IMessageQueue
    {
        public bool Fail;
        public int Count;
        public Task SendAsync(string message, CancellationToken token)
        {
            if (Fail) throw new IOException();
            Count++;
            return Task.CompletedTask;
        }
    }
    private sealed class MemoryReceipts : IReceiptStore
    {
        public bool Done, Busy;
        public Task<IReceipt?> AcquireAsync(string id, CancellationToken token) =>
            Task.FromResult<IReceipt?>(Busy ? null : new Receipt(this));
        private sealed class Receipt(MemoryReceipts store) : IReceipt
        {
            public bool Completed => store.Done;
            public Task CompleteAsync(CancellationToken token) { store.Done = true; return Task.CompletedTask; }
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }
}

public sealed class StorageTests
{
    [Fact]
    [Trait("Category", "Storage")]
    public async Task SharedReceiptsSerializeRequestsAndAllowRetry()
    {
        var connection = Environment.GetEnvironmentVariable("RELAY_TEST_STORAGE") ?? "UseDevelopmentStorage=true";
        var suffix = Guid.NewGuid().ToString("N");
        var container = new BlobContainerClient(connection, "receipts-" + suffix);
        var queue = new QueueClient(connection, "queue-" + suffix,
            new QueueClientOptions { MessageEncoding = QueueMessageEncoding.Base64, Retry = { MaxRetries = 0 } });
        await container.CreateAsync();
        try
        {
            var firstStore = new BlobReceiptStore(container);
            var secondStore = new BlobReceiptStore(container);
            await using (var claim = await firstStore.AcquireAsync("123", default))
            {
                Assert.NotNull(claim);
                Assert.Null(await secondStore.AcquireAsync("123", default));
            }
            var first = new InteractionDispatcher(firstStore, new AzureMessageQueue(queue));
            // Queue does not exist: failure must not permanently claim the ID.
            await Assert.ThrowsAsync<Azure.RequestFailedException>(() => first.DispatchAsync("123", "payload", default));
            await queue.CreateAsync();
            Assert.Equal(DispatchResult.Accepted, await first.DispatchAsync("123", "payload", default));
            var second = new InteractionDispatcher(secondStore, new AzureMessageQueue(queue));
            Assert.Equal(DispatchResult.Duplicate, await second.DispatchAsync("123", "payload", default));
            var messages = (await queue.ReceiveMessagesAsync(10)).Value;
            Assert.Single(messages);
            Assert.Equal("payload", messages[0].MessageText);
        }
        finally
        {
            await queue.DeleteIfExistsAsync();
            await container.DeleteIfExistsAsync();
        }
    }
}
