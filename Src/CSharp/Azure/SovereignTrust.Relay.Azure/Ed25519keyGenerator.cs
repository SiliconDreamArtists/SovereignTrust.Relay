using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using NSec.Cryptography;

namespace SovereignTrust.Relay.Azure.Azure
{
    // TODO: Move this into common library
    public class Ed25519KeyGenerator
    {
        private readonly ILogger<Ed25519KeyGenerator> _logger;

        public Ed25519KeyGenerator(ILogger<Ed25519KeyGenerator> logger)
        {
            _logger = logger;
        }

        [Function("GenerateEd25519KeyPair")]
        public async Task<IActionResult> Run(
            [HttpTrigger(AuthorizationLevel.Function, "get", Route = null)] HttpRequest req)
        {
            _logger.LogInformation("🔐 Generating new Ed25519 key pair.");

            var algorithm = SignatureAlgorithm.Ed25519;
            var key = Key.Create(algorithm, new KeyCreationParameters
            {
                ExportPolicy = KeyExportPolicies.AllowPlaintextExport
            });

            var publicKeyHex = Convert.ToHexString(key.PublicKey.Export(KeyBlobFormat.RawPublicKey)).ToLower();
            var privateKeyHex = Convert.ToHexString(key.Export(KeyBlobFormat.RawPrivateKey)).ToLower();

            var response = new
            {
                publicKey = publicKeyHex,
                privateKey = privateKeyHex,
                exportNote = "Save these values securely and set them as DISCORD_PUBLIC_KEY and DISCORD_PRIVATE_KEY in your function configuration."
            };

            return new JsonResult(response);
        }
    }
}
