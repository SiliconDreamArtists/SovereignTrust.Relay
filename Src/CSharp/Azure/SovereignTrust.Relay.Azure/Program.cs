using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using Microsoft.Azure.Functions.Worker.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using SovereignTrust.Relay.Azure;
using SovereignTrust.Relay.Azure.Azure.Discord;

var builder = FunctionsApplication.CreateBuilder(args);
builder.ConfigureFunctionsWebApplication();
var settings = RelaySettings.Load(builder.Configuration);
builder.Services.AddSingleton(settings);
builder.Services.AddSingleton(TimeProvider.System);
builder.Services.AddSingleton(new QueueClient(settings.StorageConnection, settings.QueueName,
    new QueueClientOptions { MessageEncoding = QueueMessageEncoding.Base64, Retry = { MaxRetries = 0 } }));
builder.Services.AddSingleton(new BlobContainerClient(settings.StorageConnection, settings.DedupContainer,
    new BlobClientOptions { Retry = { MaxRetries = 0 } }));
builder.Services.AddSingleton<IReceiptStore, BlobReceiptStore>();
builder.Services.AddSingleton<IMessageQueue, AzureMessageQueue>();
builder.Services.AddSingleton<IInteractionDispatcher, InteractionDispatcher>();
var host = builder.Build();
SignalGraph.Signal.Logger = host.Services.GetRequiredService<ILoggerFactory>().CreateLogger("SignalGraph");
host.Run();
