using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using SovereignTrust.Relay.Azure;
using SovereignTrust.Relay.Azure.Azure.Discord;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddControllers();
builder.Services.AddSingleton(services => RelaySettings.Load(services.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton<TokenCredential>(_ => new ManagedIdentityCredential(ManagedIdentityId.SystemAssigned));
builder.Services.AddSingleton(new QueueClientOptions { MessageEncoding = QueueMessageEncoding.Base64, Retry = { MaxRetries = 0 } });
builder.Services.AddSingleton(new BlobClientOptions { Retry = { MaxRetries = 0 } });
builder.Services.AddSingleton(services =>
{
    var settings = services.GetRequiredService<RelaySettings>();
    return new QueueClient(settings.QueueUri, services.GetRequiredService<TokenCredential>(),
        services.GetRequiredService<QueueClientOptions>());
});
builder.Services.AddSingleton(services =>
{
    var settings = services.GetRequiredService<RelaySettings>();
    return new BlobContainerClient(settings.ContainerUri, services.GetRequiredService<TokenCredential>(),
        services.GetRequiredService<BlobClientOptions>());
});
builder.Services.AddSingleton<IReceiptStore, BlobReceiptStore>();
builder.Services.AddSingleton<IMessageQueue, AzureMessageQueue>();
builder.Services.AddSingleton<IInteractionDispatcher, InteractionDispatcher>();
var app = builder.Build();
_ = app.Services.GetRequiredService<RelaySettings>(); // Fail startup on invalid syntax, without contacting storage.
SignalGraph.Signal.Logger = app.Services.GetRequiredService<ILoggerFactory>().CreateLogger("SignalGraph");
app.MapControllers();
app.MapGet("/healthz", () => Results.Ok(new { status = "ready" }));
app.Run();

public partial class Program { }
