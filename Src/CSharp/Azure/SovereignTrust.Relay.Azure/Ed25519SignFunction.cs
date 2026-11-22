using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using NSec.Cryptography;
using SovereignTrust.Relay.Azure;
namespace SovereignTrust.Relay.Azure.Azure;

[Controller]
public sealed class Ed25519SignFunction(RelaySettings settings, TimeProvider clock) : ControllerBase
{
    [HttpPost("/api/Ed25519SignFunction")]
    public Task<IActionResult> HttpRun() => Run(Request);

    [NonAction]
    public async Task<IActionResult> Run(HttpRequest req)
    {
        if (!settings.SigningEnabled) return new NotFoundResult();
        if (!HelperAuthorization.IsAuthorized(req, settings.HelperApiKey)) return new UnauthorizedResult();
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
