using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using SovereignTrust.Relay.Azure;
namespace SovereignTrust.Relay.Azure.Azure.Discord;

public sealed class DiscordRelay(ILogger<DiscordRelay> logger, RelaySettings settings,
    IInteractionDispatcher dispatcher, TimeProvider clock)
{
    [Function(nameof(DiscordRelay))]
    public async Task<IActionResult> RunDiscordRelayAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "post", Route = "discordrelay")] HttpRequest req)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(req.HttpContext.RequestAborted);
        deadline.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            using var reader = new StreamReader(req.Body, new UTF8Encoding(false, true),
                detectEncodingFromByteOrderMarks: false, leaveOpen: true);
            var buffer = new char[65537];
            var length = 0;
            while (length < buffer.Length)
            {
                var read = await reader.ReadAsync(buffer.AsMemory(length), deadline.Token);
                if (read == 0) break;
                length += read;
            }
            if (length == buffer.Length) return new StatusCodeResult(StatusCodes.Status413PayloadTooLarge);
            var body = new string(buffer, 0, length);
            if (!DiscordVerifier.IsValidRequest(req, body, settings.PublicKey, logger, clock))
                return new UnauthorizedResult();
            JObject payload;
            try { payload = JObject.Parse(body); }
            catch (JsonException) { return new BadRequestObjectResult("Invalid JSON."); }
            if (payload["type"]?.Type != JTokenType.Integer)
                return new BadRequestObjectResult("Invalid interaction type.");
            var type = payload.Value<long>("type");
            if (type == 1) return new JsonResult(new { type = 1 });
            if (type is not (2 or 3 or 5)) return new BadRequestObjectResult("Unsupported interaction type.");
            if (payload["id"]?.Type is not (JTokenType.String or JTokenType.Integer))
                return new BadRequestObjectResult("Missing or invalid interaction ID.");
            var id = payload.Value<string>("id");
            if (!ulong.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out var interactionId) || interactionId == 0)
                return new BadRequestObjectResult("Missing or invalid interaction ID.");

            // Preserve Result.id as the downstream consumer's idempotency key.
            var signal = SignalGraph.Signal.Start<JObject>(payload);
            signal.LogInformation("Received packet from Discord.");
            var json = signal.ToJson();
            if (Encoding.UTF8.GetByteCount(json) > 48 * 1024)
                return new StatusCodeResult(StatusCodes.Status413PayloadTooLarge);
            var result = await dispatcher.DispatchAsync(interactionId.ToString(CultureInfo.InvariantCulture), json, deadline.Token);
            if (result == DispatchResult.Busy) return new StatusCodeResult(StatusCodes.Status503ServiceUnavailable);
            return new JsonResult(new { type = 5 });
        }
        catch (DecoderFallbackException) { return new BadRequestObjectResult("Invalid UTF-8."); }
        catch (OperationCanceledException)
        {
            logger.LogWarning("Discord request exceeded its deadline or was canceled.");
            return new StatusCodeResult(StatusCodes.Status503ServiceUnavailable);
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Discord relay could not durably enqueue the interaction.");
            return new StatusCodeResult(StatusCodes.Status503ServiceUnavailable);
        }
    }
}
