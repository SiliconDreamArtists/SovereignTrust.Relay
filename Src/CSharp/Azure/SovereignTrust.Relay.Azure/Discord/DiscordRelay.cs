using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Azure.Storage.Queues;
using System.Text;
using Microsoft.Extensions.Configuration;

namespace SovereignTrust.Relay.Azure.Azure.Discord
{
    /// <summary>
    /// Stateless webhook handler that receives external input and enqueues structured Signal<T> objects into SovereignTrust queues
    /// </summary>
    public class DiscordRelay
    {
        private readonly ILogger<DiscordRelay> _logger;
        private readonly IConfiguration _config;

        public DiscordRelay(ILogger<DiscordRelay> logger, IConfiguration config)
        {
            _logger = logger;
            _config = config;
            SignalCore.Signal.Logger = logger;
        }

        [Function(nameof(DiscordRelay))]
        public async Task<IActionResult> RunDiscordRelayAsync(
            [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "discord")] HttpRequest req)
        {
            _logger.LogInformation("📥 Discord relay function triggered.");

            string requestBody;
            using (StreamReader streamReader = new StreamReader(req.Body))
            {
                requestBody = await streamReader.ReadToEndAsync();
            }

            if (string.IsNullOrWhiteSpace(requestBody))
            {
                _logger.LogWarning("⚠️ Empty body received.");
                return new BadRequestObjectResult("Empty request body.");
            }

            string discordPublicKey = _config["DISCORD_PUBLIC_KEY"]; // from Discord Developer Portal

            if (!DiscordVerifier.IsValidRequest(req, requestBody, discordPublicKey, _logger))
            {
                _logger.LogWarning("❌ Discord signature validation failed.");
                return new UnauthorizedResult();
            }

            //todo: Add Support for trusted connection.

            string storageConnection = _config["StorageQueueAccount"];
            string queueName = _config["DISCORD_QUEUE_NAME"] ?? "discord-interactions";

            try
            {
                QueueClient queueClient = new QueueClient(storageConnection, queueName);
                await queueClient.CreateIfNotExistsAsync();

                if (queueClient.Exists())
                {
                    SignalCore.Signal<dynamic> signalCore = SignalCore.Signal.Start<dynamic>(Newtonsoft.Json.JsonConvert.DeserializeObject(requestBody));
                    signalCore.LogInformation("Received packet from Discord.");
                    string signalCoreJson = Newtonsoft.Json.JsonConvert.SerializeObject(signalCore);
                    await queueClient.SendMessageAsync(Convert.ToBase64String(Encoding.UTF8.GetBytes(signalCoreJson)));
                    _logger.LogInformation("✅ Message enqueued successfully.");
                    return DiscordInteractionResponseHelper.HandleInteraction(requestBody, _logger);
                }
                else
                {
                    _logger.LogError("❌ Failed to access or create queue.");
                    return new StatusCodeResult(StatusCodes.Status500InternalServerError);
                }
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "❌ Exception during queueing.");
                return new StatusCodeResult(StatusCodes.Status500InternalServerError);
            }
        }
    }
}
