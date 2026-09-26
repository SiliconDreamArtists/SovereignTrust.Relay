using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using NSec.Cryptography;
using SovereignTrust.Relay.Azure;
namespace SovereignTrust.Relay.Azure.Azure;

public sealed class Ed25519SignFunction(RelaySettings settings, TimeProvider clock)
{
    [Function("Ed25519SignFunction")]
    public async Task<IActionResult> Run([HttpTrigger(AuthorizationLevel.Function, "post")] HttpRequest req)
    {
        if (!settings.SigningEnabled) return new NotFoundResult();
        using var reader = new StreamReader(req.Body);
        var body = await reader.ReadToEndAsync(req.HttpContext.RequestAborted);
        if (string.IsNullOrWhiteSpace(body)) return new BadRequestObjectResult("Empty request body.");
        var timestamp = clock.GetUtcNow().ToUnixTimeSeconds().ToString(CultureInfo.InvariantCulture);
        using var key = Key.Import(SignatureAlgorithm.Ed25519, Convert.FromHexString(settings.TestPrivateKey!), KeyBlobFormat.RawPrivateKey);
        var signature = SignatureAlgorithm.Ed25519.Sign(key, Encoding.UTF8.GetBytes(timestamp + body));
        return new JsonResult(new
        {
            timestamp,
            signature = Convert.ToHexString(signature).ToLowerInvariant(),
            publicKey = Convert.ToHexString(key.PublicKey.Export(KeyBlobFormat.RawPublicKey)).ToLowerInvariant(),
            original = body
        });
    }
}
