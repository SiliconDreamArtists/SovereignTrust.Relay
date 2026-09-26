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

        private readonly SovereignTrust.Relay.Azure.RelaySettings _settings;

        public Ed25519KeyGenerator(ILogger<Ed25519KeyGenerator> logger, SovereignTrust.Relay.Azure.RelaySettings settings)
        {
            _logger = logger;
            _settings = settings;
        }

        [Function("GenerateEd25519KeyPair")]
        public IActionResult Run(
            [HttpTrigger(AuthorizationLevel.Function, "get", Route = null)] HttpRequest req)
        {
            if (!_settings.SigningEnabled) return new NotFoundResult();
            _logger.LogInformation("Generating a test Ed25519 key pair.");

            var algorithm = SignatureAlgorithm.Ed25519;
            using var key = Key.Create(algorithm, new KeyCreationParameters
            {
                ExportPolicy = KeyExportPolicies.AllowPlaintextExport
            });

            var publicKeyHex = Convert.ToHexString(key.PublicKey.Export(KeyBlobFormat.RawPublicKey)).ToLower();
            var privateKeyHex = Convert.ToHexString(key.Export(KeyBlobFormat.RawPrivateKey)).ToLower();

            var response = new
            {
                publicKey = publicKeyHex,
                privateKey = privateKeyHex,
                exportNote = "Test keys only. Store the private key as DISCORD_TEST_PRIVATE_KEY. Never replace the real Discord application's public key with a generated test key."
            };

            return new JsonResult(response);
        }
    }
}
