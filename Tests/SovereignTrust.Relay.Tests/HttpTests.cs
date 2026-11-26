using System.Globalization;
using System.Net;
using System.Text;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Newtonsoft.Json.Linq;
using NSec.Cryptography;
using SovereignTrust.Relay.Azure;
using SovereignTrust.Relay.Azure.Azure.Discord;
using Xunit;

public sealed class HttpTests : IDisposable
{
    private readonly long now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
    private readonly Key key = Key.Create(SignatureAlgorithm.Ed25519,
        new KeyCreationParameters { ExportPolicy = KeyExportPolicies.AllowPlaintextExport });
    public void Dispose() => key.Dispose();

    private Host CreateHost(bool enabled = false) => new(key, enabled, now);
    private HttpRequestMessage Signed(string body, int offset = 0)
    {
        var stamp = (now + offset).ToString(CultureInfo.InvariantCulture);
        var req = new HttpRequestMessage(HttpMethod.Post, "/api/discordrelay") { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        req.Headers.Add("X-Signature-Timestamp", stamp);
        req.Headers.Add("X-Signature-Ed25519", Convert.ToHexString(SignatureAlgorithm.Ed25519.Sign(key, Encoding.UTF8.GetBytes(stamp + body))));
        return req;
    }

    [Fact]
    public async Task RoutesExecuteRealJsonAndHelpersStayDisabled()
    {
        await using var host = CreateHost(); using var client = host.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/healthz")).StatusCode);
        Assert.Equal(HttpStatusCode.MethodNotAllowed, (await client.GetAsync("/api/discordrelay")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/unknown")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsync("/api/discordrelay", new StringContent("{}"))).StatusCode);
        host.Dispatcher.Fail = true;
        var ping = await client.SendAsync(Signed("{\"type\":1}"));
        Assert.Equal(HttpStatusCode.OK, ping.StatusCode);
        Assert.Equal(1, JObject.Parse(await ping.Content.ReadAsStringAsync()).Value<int>("type"));
        Assert.Equal(0, host.Dispatcher.Calls);
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync("/api/Ed25519SignFunction", new StringContent("body"))).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/api/GenerateEd25519KeyPair")).StatusCode);
    }

    [Theory]
    [InlineData(2)] [InlineData(3)] [InlineData(5)]
    public async Task AcceptedTypesPreserveQueueEnvelope(int type)
    {
        await using var host = CreateHost(); using var client = host.CreateClient();
        var response = await client.SendAsync(Signed($"{{\"type\":{type},\"id\":\"123\"}}"));
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
        Assert.Equal(5, JObject.Parse(await response.Content.ReadAsStringAsync()).Value<int>("type"));
        Assert.Equal("123", JObject.Parse(host.Dispatcher.Message!)["Result"]!.Value<string>("id"));
    }

    [Theory]
    [InlineData("{\"type\":2,\"id\":\"0\"}")]
    [InlineData("{\"type\":2,\"id\":\"18446744073709551616\"}")]
    [InlineData("{\"type\":2.5,\"id\":\"123\"}")]
    [InlineData("not-json")]
    public async Task BadPayloadCannotDispatch(string body)
    {
        await using var host = CreateHost(); using var client = host.CreateClient();
        Assert.Equal(HttpStatusCode.BadRequest, (await client.SendAsync(Signed(body))).StatusCode);
        Assert.Equal(0, host.Dispatcher.Calls);
    }

    [Theory]
    [InlineData(-301, false)] [InlineData(31, false)]
    [InlineData(-300, true)] [InlineData(30, true)]
    public async Task TimestampWindow(int offset, bool accepted)
    {
        await using var host = CreateHost(); using var client = host.CreateClient();
        Assert.Equal(accepted ? HttpStatusCode.OK : HttpStatusCode.Unauthorized,
            (await client.SendAsync(Signed("{\"type\":1}", offset))).StatusCode);
    }

    [Fact]
    public async Task BodyLimitsAndMalformedUtf8RejectWithoutDispatch()
    {
        await using var host = CreateHost(); using var client = host.CreateClient();
        var prefix = "{\"type\":1,\"padding\":\""; const string suffix = "\"}";
        var body = prefix + new string('x', 65536 - prefix.Length - suffix.Length) + suffix;
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(Signed(body))).StatusCode);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, (await client.SendAsync(Signed(body + " "))).StatusCode);
        var request = Signed("{}"); request.Content = new ByteArrayContent([0xff]);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.SendAsync(request)).StatusCode);
        Assert.Equal(0, host.Dispatcher.Calls);
    }

    [Fact]
    public async Task HelperAuthorizationIsEnforcedOverHttp()
    {
        await using var host = CreateHost(true); using var client = host.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/GenerateEd25519KeyPair?code=local-test-key")).StatusCode);
        client.DefaultRequestHeaders.Add("x-functions-key", "wrong");
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsync("/api/Ed25519SignFunction", new StringContent("body"))).StatusCode);
        client.DefaultRequestHeaders.Remove("x-functions-key"); client.DefaultRequestHeaders.Add("x-functions-key", ["local-test-key", "extra"]);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/GenerateEd25519KeyPair")).StatusCode);
        client.DefaultRequestHeaders.Remove("x-functions-key"); client.DefaultRequestHeaders.Add("x-functions-key", "local-test-key");
        var signed = await client.PostAsync("/api/Ed25519SignFunction", new StringContent("body"));
        Assert.Equal(HttpStatusCode.OK, signed.StatusCode);
        var json = JObject.Parse(await signed.Content.ReadAsStringAsync()); Assert.Null(json["privateKey"]);
        Assert.True(SignatureAlgorithm.Ed25519.Verify(key.PublicKey, Encoding.UTF8.GetBytes(json.Value<string>("timestamp") + "body"), Convert.FromHexString(json.Value<string>("signature")!)));
        var generated = await client.GetAsync("/api/GenerateEd25519KeyPair");
        Assert.Equal(HttpStatusCode.OK, generated.StatusCode);
        Assert.NotNull(JObject.Parse(await generated.Content.ReadAsStringAsync())["privateKey"]);
    }

    [Fact]
    public async Task StorageDeadlineAndFailureAre503()
    {
        await using var host = CreateHost(); using var client = host.CreateClient();
        host.Dispatcher.Fail = true;
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.SendAsync(Signed("{\"type\":2,\"id\":\"123\"}"))).StatusCode);
        host.Dispatcher.Fail = false; host.Dispatcher.Wait = true;
        var elapsed = System.Diagnostics.Stopwatch.StartNew();
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.SendAsync(Signed("{\"type\":2,\"id\":\"124\"}"))).StatusCode);
        Assert.InRange(elapsed.Elapsed.TotalSeconds, 1.8, 3.5); // Test-host scheduling tolerance, not a production latency guarantee.
        Assert.True(host.Dispatcher.Canceled);
    }

    [Theory]
    [InlineData("missing")] [InlineData("multiple")] [InlineData("malformed")] [InlineData("tampered")]
    public async Task InvalidSignatureHeadersCannotDispatch(string mode)
    {
        await using var host = CreateHost(); using var client = host.CreateClient();
        var request = Signed("{\"type\":2,\"id\":\"123\"}");
        if (mode == "missing") request.Headers.Remove("X-Signature-Timestamp");
        if (mode == "multiple") request.Headers.Add("X-Signature-Timestamp", now.ToString(CultureInfo.InvariantCulture));
        if (mode == "malformed") { request.Headers.Remove("X-Signature-Ed25519"); request.Headers.Add("X-Signature-Ed25519", "not-hex"); }
        if (mode == "tampered") request.Content = new StringContent("{\"type\":2,\"id\":\"124\"}");
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.SendAsync(request)).StatusCode);
        Assert.Equal(0, host.Dispatcher.Calls);
    }

    [Fact]
    public async Task SerializedUtf8LimitRejectsBeforeQueue()
    {
        await using var host = CreateHost(); using var client = host.CreateClient();
        const string empty = "{\"type\":2,\"id\":\"123\",\"padding\":\"\"}";
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(Signed(empty))).StatusCode);
        var overhead = Encoding.UTF8.GetByteCount(host.Dispatcher.Message!);
        // SignalGraph uses wall-clock log timestamps with variable fractional precision.
        // Leave a small margin instead of assuming two envelopes have byte-identical overhead.
        var body = empty.Replace("\"padding\":\"\"", "\"padding\":\"" + new string('x', 48 * 1024 - overhead - 64) + "\"");
        Assert.Equal(HttpStatusCode.OK, (await client.SendAsync(Signed(body))).StatusCode);
        Assert.InRange(Encoding.UTF8.GetByteCount(host.Dispatcher.Message!), 48 * 1024 - 80, 48 * 1024);
        var calls = host.Dispatcher.Calls;
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, (await client.SendAsync(Signed(body.Replace("padding\":\"", "padding\":\"" + new string('x', 128))))).StatusCode);
        Assert.Equal(HttpStatusCode.RequestEntityTooLarge, (await client.SendAsync(Signed(empty.Replace("\"padding\":\"\"", "\"padding\":\"" + new string('é', 25000) + "\"")))).StatusCode);
        Assert.Equal(calls, host.Dispatcher.Calls);
    }

    private sealed class Host(Key key, bool enabled, long now) : WebApplicationFactory<Program>
    {
        public readonly Dispatcher Dispatcher = new();
        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["DISCORD_PUBLIC_KEY"] = Convert.ToHexString(key.PublicKey.Export(KeyBlobFormat.RawPublicKey)),
                ["DISCORD_STORAGE_ACCOUNT_NAME"] = "localfixture",
                ["DISCORD_QUEUE_NAME"] = "queue-fixture", ["DISCORD_DEDUP_CONTAINER"] = "receipts-fixture", ["ENABLE_ED25519_SIGNING"] = enabled.ToString(),
                ["RELAY_HELPER_API_KEY"] = "local-test-key", ["DISCORD_TEST_PRIVATE_KEY"] = enabled ? Convert.ToHexString(key.Export(KeyBlobFormat.RawPrivateKey)) : null
            }));
            builder.ConfigureServices(services =>
            {
                services.RemoveAll<IInteractionDispatcher>(); services.AddSingleton<IInteractionDispatcher>(Dispatcher);
                services.RemoveAll<TimeProvider>(); services.AddSingleton<TimeProvider>(new Clock(now));
            });
        }
    }
    private sealed class Clock(long now) : TimeProvider { public override DateTimeOffset GetUtcNow() => DateTimeOffset.FromUnixTimeSeconds(now); }
    private sealed class Dispatcher : IInteractionDispatcher
    {
        public int Calls; public string? Message; public bool Fail, Wait, Canceled;
        public async Task<DispatchResult> DispatchAsync(string id, string message, CancellationToken cancellationToken)
        {
            Calls++; Message = message; if (Fail) throw new IOException("isolated storage failure");
            try { if (Wait) await Task.Delay(Timeout.Infinite, cancellationToken); }
            catch (OperationCanceledException) { Canceled = true; throw; }
            return DispatchResult.Accepted;
        }
    }
}
