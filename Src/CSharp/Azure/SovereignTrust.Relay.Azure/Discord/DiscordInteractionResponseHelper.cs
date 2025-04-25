using Microsoft.AspNetCore.Mvc;
using Newtonsoft.Json.Linq;
using Microsoft.Extensions.Logging;
namespace SovereignTrust.Relay.Azure.Azure.Discord
{
    public static class DiscordInteractionResponseHelper
    {
        public static IActionResult HandleInteraction(string requestBody, ILogger log)
        {
            if (string.IsNullOrWhiteSpace(requestBody))
            {
                log.LogWarning("⚠️ Empty request body.");
                return new BadRequestObjectResult("Empty request body.");
            }

            JObject payload;
            try
            {
                payload = JObject.Parse(requestBody);
            }
            catch (Exception ex)
            {
                log.LogWarning($"⚠️ Could not parse JSON body: {ex.Message}");
                return new BadRequestObjectResult("Invalid JSON.");
            }

            int type = payload.Value<int?>("type") ?? -1;

            switch (type)
            {
                case 1:
                    log.LogInformation("✅ Received Ping, responding with type 1.");
                    return new JsonResult(new { type = 1 });

                case 2:
                case 3:
                case 5:
                    log.LogInformation($"⏳ Received interaction type {type}, returning deferred response (type 5).");
                    return new JsonResult(new { type = 5 });

                default:
                    log.LogWarning($"❌ Unknown interaction type: {type}");
                    return new BadRequestObjectResult($"Unsupported interaction type: {type}");
            }
        }
    }
}