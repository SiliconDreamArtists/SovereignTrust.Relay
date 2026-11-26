using System.Net;
using System.Text;
using Azure;
using Azure.Core;
using Azure.Core.Pipeline;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using NSec.Cryptography;
using SovereignTrust.Relay.Azure;
using Xunit;

public sealed class StorageAuthenticationTests
{
    private static Dictionary<string, string?> Configuration()
    {
        using var key = Key.Create(SignatureAlgorithm.Ed25519);
        return new()
        {
            ["DISCORD_PUBLIC_KEY"] = Convert.ToHexString(key.PublicKey.Export(KeyBlobFormat.RawPublicKey)),
            ["DISCORD_STORAGE_ACCOUNT_NAME"] = "localfixture",
            ["DISCORD_QUEUE_NAME"] = "queue-fixture",
            ["DISCORD_DEDUP_CONTAINER"] = "receipts-fixture",
            ["ENABLE_ED25519_SIGNING"] = "false"
        };
    }

    public static IEnumerable<object?[]> InvalidIdentifiers()
    {
        foreach (var name in new[] { "DISCORD_STORAGE_ACCOUNT_NAME", "DISCORD_QUEUE_NAME", "DISCORD_DEDUP_CONTAINER" })
            foreach (var value in new string?[] { null, "", " ", "ab", new('a', 64), "UPPERCASE", "bad--name", "validname\n", "https://external.invalid", "@Microsoft.KeyVault(SecretUri=fixture)" })
                yield return [name, value];
        yield return ["DISCORD_STORAGE_ACCOUNT_NAME", new string('a', 25)];
        yield return ["DISCORD_STORAGE_ACCOUNT_NAME", "account-name"];
    }

    [Theory]
    [MemberData(nameof(InvalidIdentifiers))]
    public void RequiredIdentifiersRejectMalformedValuesWithoutDisclosingThem(string name, string? value)
    {
        var values = Configuration();
        values[name] = value;
        // A legacy local-test credential must never satisfy a missing/invalid runtime identifier.
        values["StorageQueueAccount"] = "UseDevelopmentStorage=true";
        var error = Assert.Throws<InvalidOperationException>(() => RelaySettings.Load(
            new ConfigurationBuilder().AddInMemoryCollection(values).Build()));
        Assert.Contains(name, error.Message);
        if (!string.IsNullOrWhiteSpace(value)) Assert.DoesNotContain(value, error.Message);
    }

    [Fact]
    public void LegacyCredentialsCannotRedirectExplicitEndpoints()
    {
        var values = Configuration();
        values["StorageQueueAccount"] = "UseDevelopmentStorage=true";
        values["AZURE_STORAGE_CONNECTION_STRING"] = "AccountName=externalfixture;AccountKey=fixture";
        values["AZURE_STORAGE_ACCOUNT"] = "externalfixture";
        values["AZURE_CLIENT_ID"] = "unrelated-deployment-identity";
        var settings = RelaySettings.Load(new ConfigurationBuilder().AddInMemoryCollection(values).Build());
        Assert.Equal("https://localfixture.queue.core.windows.net/queue-fixture", settings.QueueUri.AbsoluteUri);
        Assert.Equal("https://localfixture.blob.core.windows.net/receipts-fixture", settings.ContainerUri.AbsoluteUri);
    }

    [Fact]
    public async Task ProductionRegistrationUsesManagedIdentityWithoutAuthenticatingAtStartup()
    {
        await using var host = new Host();
        using var client = host.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/healthz")).StatusCode);
        Assert.IsType<ManagedIdentityCredential>(host.Services.GetRequiredService<TokenCredential>());
        Assert.Equal("localfixture.queue.core.windows.net", host.Services.GetRequiredService<QueueClient>().Uri.Host);
        Assert.Equal("localfixture.blob.core.windows.net", host.Services.GetRequiredService<BlobContainerClient>().Uri.Host);
    }

    [Fact]
    public async Task BothRegisteredClientsUseBearerTokensBase64AndNoRetries()
    {
        var credential = new FixtureCredential();
        using var handler = new RejectingStorageHandler();
        using var transportClient = new HttpClient(handler);
        await using var host = new Host(credential, transportClient);
        using var client = host.CreateClient();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/healthz")).StatusCode);
        Assert.Empty(credential.Scopes); // Startup does not contact identity/storage.
        var queue = host.Services.GetRequiredService<QueueClient>();
        var blobs = host.Services.GetRequiredService<BlobContainerClient>();
        Assert.Equal(QueueMessageEncoding.Base64, host.Services.GetRequiredService<QueueClientOptions>().MessageEncoding);
        Assert.Equal(0, host.Services.GetRequiredService<QueueClientOptions>().Retry.MaxRetries);
        Assert.Equal(0, host.Services.GetRequiredService<BlobClientOptions>().Retry.MaxRetries);

        await Assert.ThrowsAsync<RequestFailedException>(() => queue.SendMessageAsync("payload"));
        await Assert.ThrowsAsync<RequestFailedException>(() => blobs.GetBlobClient("123").GetPropertiesAsync());

        Assert.Equal(2, handler.Requests.Count); // One attempt for each injected 503.
        Assert.Equal("https://localfixture.queue.core.windows.net/queue-fixture/messages", handler.Requests[0].Uri.GetLeftPart(UriPartial.Path));
        Assert.Contains("<MessageText>" + Convert.ToBase64String(Encoding.UTF8.GetBytes("payload")) + "</MessageText>", handler.Requests[0].Body);
        Assert.Equal("https://localfixture.blob.core.windows.net/receipts-fixture/123", handler.Requests[1].Uri.GetLeftPart(UriPartial.Path));
        Assert.All(handler.Requests, request => Assert.Equal("Bearer local-test-token", request.Authorization));
        Assert.Equal(2, credential.Scopes.Count);
        Assert.All(credential.Scopes, scope => Assert.Equal("https://storage.azure.com//.default", scope));
    }

    private sealed class Host(FixtureCredential? credential = null, HttpClient? transportClient = null) : WebApplicationFactory<Program>
    {
        protected override void ConfigureWebHost(IWebHostBuilder builder)
        {
            builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(Configuration()));
            if (credential is null) return;
            builder.ConfigureServices(services =>
            {
                services.RemoveAll<TokenCredential>();
                services.AddSingleton<TokenCredential>(credential);
                // Replace transport only; assertions exercise the actual production encoding/retry options.
                ((QueueClientOptions)services.Single(service => service.ServiceType == typeof(QueueClientOptions)).ImplementationInstance!)
                    .Transport = new HttpClientTransport(transportClient!);
                ((BlobClientOptions)services.Single(service => service.ServiceType == typeof(BlobClientOptions)).ImplementationInstance!)
                    .Transport = new HttpClientTransport(transportClient!);
            });
        }
    }

    private sealed class FixtureCredential : TokenCredential
    {
        public List<string> Scopes { get; } = [];
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Scopes.AddRange(requestContext.Scopes);
            return new AccessToken("local-test-token", DateTimeOffset.UtcNow.AddHours(1));
        }
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class RejectingStorageHandler : HttpMessageHandler
    {
        public List<(Uri Uri, string? Authorization, string Body)> Requests { get; } = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests.Add((request.RequestUri!, request.Headers.Authorization?.ToString(),
                request.Content is null ? "" : await request.Content.ReadAsStringAsync(cancellationToken)));
            return new(HttpStatusCode.ServiceUnavailable)
            {
                Content = new StringContent("<Error><Code>ServerBusy</Code><Message>Local injected failure</Message></Error>"),
                Headers = { { "x-ms-error-code", "ServerBusy" } }
            };
        }
    }
}
