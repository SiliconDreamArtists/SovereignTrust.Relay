using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;
using NSec.Cryptography;
namespace SovereignTrust.Relay.Azure.Azure.Discord;

public static class DiscordVerifier
{
    public const int MaxAgeSeconds = 300;
    public const int FutureSkewSeconds = 30;
    public static bool IsValidRequest(HttpRequest req, string body, string publicKeyHex,
        ILogger log, TimeProvider? clock = null)
    {
        if (!req.Headers.TryGetValue("X-Signature-Ed25519", out var signature) || signature.Count != 1 ||
            !req.Headers.TryGetValue("X-Signature-Timestamp", out var timestamp) || timestamp.Count != 1 ||
            !long.TryParse(timestamp.ToString(), NumberStyles.None, CultureInfo.InvariantCulture, out var seconds))
            return false;
        var now = (clock ?? TimeProvider.System).GetUtcNow().ToUnixTimeSeconds();
        if (seconds < now - MaxAgeSeconds || seconds > now + FutureSkewSeconds) return false;
        try
        {
            var bytes = Convert.FromHexString(signature.ToString());
            if (bytes.Length != 64) return false;
            var key = PublicKey.Import(SignatureAlgorithm.Ed25519, Convert.FromHexString(publicKeyHex), KeyBlobFormat.RawPublicKey);
            return SignatureAlgorithm.Ed25519.Verify(key, Encoding.UTF8.GetBytes(timestamp.ToString() + body), bytes);
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException)
        {
            log.LogWarning("Malformed Discord signature or public key.");
            return false;
        }
    }
}
