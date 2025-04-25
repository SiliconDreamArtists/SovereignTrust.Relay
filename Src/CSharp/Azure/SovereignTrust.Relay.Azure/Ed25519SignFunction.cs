using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using NSec.Cryptography;
using Microsoft.Extensions.Configuration;

namespace SovereignTrust.Relay.Azure.Azure
{
    // TODO: Move this into common library
    public class Ed25519SignFunction
    {
        private readonly ILogger<Ed25519SignFunction> _logger;
        private readonly IConfiguration _config;

        public Ed25519SignFunction(ILogger<Ed25519SignFunction> logger, IConfiguration config)
        {
            _logger = logger;
            _config = config;
        }

        [Function("Ed25519SignFunction")]
        public async Task<IActionResult> Run(
            [HttpTrigger(AuthorizationLevel.Anonymous, "post")] HttpRequest req)
        {
            _logger.LogInformation("📥 Ed25519 signing function triggered.");

            string requestBody;
            using (var streamReader = new StreamReader(req.Body))
            {
                requestBody = await streamReader.ReadToEndAsync();
            }

            if (string.IsNullOrWhiteSpace(requestBody))
            {
                return new BadRequestObjectResult("Empty request body.");
            }

            var timestamp = ((DateTimeOffset)DateTime.UtcNow).ToUnixTimeSeconds().ToString();
            var messageBytes = Encoding.UTF8.GetBytes(timestamp + requestBody);

            var privateKeyHex = _config["DISCORD_PRIVATE_KEY"];
            if (string.IsNullOrWhiteSpace(privateKeyHex))
            {
                _logger.LogError("❌ DISCORD_PRIVATE_KEY not set.");
                return new StatusCodeResult(StatusCodes.Status500InternalServerError);
            }

            byte[] privateKeyBytes = Convert.FromHexString(privateKeyHex);
            var algorithm = SignatureAlgorithm.Ed25519;
            var key = Key.Import(algorithm, privateKeyBytes, KeyBlobFormat.RawPrivateKey);

            var signature = algorithm.Sign(key, messageBytes);
            var publicKey = key.PublicKey.Export(KeyBlobFormat.RawPublicKey);

            var response = new
            {
                timestamp = timestamp,
                signature = Convert.ToHexString(signature).ToLower(),
                publicKey = Convert.ToHexString(publicKey).ToLower(),
                privateKey = privateKeyHex.ToLower(),
                original = requestBody
            };

            return new JsonResult(response);
        }
    }
}