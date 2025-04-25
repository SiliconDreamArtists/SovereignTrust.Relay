using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using NSec.Cryptography;

namespace SovereignTrust.Relay.Azure.Azure.Discord
{
    public static class DiscordVerifier
    {
        public static bool IsValidRequest(HttpRequest req, string requestBody, string publicKeyHex, ILogger log)
        {
            if (!req.Headers.TryGetValue("X-Signature-Ed25519", out var sigHeader) ||
                !req.Headers.TryGetValue("X-Signature-Timestamp", out var timestampHeader))
            {
                log.LogWarning("❌ Missing required Discord headers.");
                return false;
            }

            string signatureHex = sigHeader.ToString();
            string timestamp = timestampHeader.ToString();

            try
            {
                byte[] messageBytes = Encoding.UTF8.GetBytes(timestamp + requestBody);
                byte[] signatureBytes = Convert.FromHexString(signatureHex);
                byte[] publicKeyBytes = Convert.FromHexString(publicKeyHex);

                var algorithm = SignatureAlgorithm.Ed25519;
                var publicKey = PublicKey.Import(algorithm, publicKeyBytes, KeyBlobFormat.RawPublicKey);

                bool isValid = algorithm.Verify(publicKey, messageBytes, signatureBytes);
                if (!isValid)
                    log.LogWarning("❌ Signature did not match.");

                return isValid;
            }
            catch (Exception ex)
            {
                log.LogError(ex, "❌ Exception during signature verification.");
                return false;
            }
        }
    }
}
