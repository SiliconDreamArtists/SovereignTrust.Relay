using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Http;

namespace SovereignTrust.Relay.Azure;

public static class HelperAuthorization
{
    public static bool IsAuthorized(HttpRequest request, string? expected)
    {
        if (string.IsNullOrEmpty(expected) ||
            !request.Headers.TryGetValue("x-functions-key", out var supplied) ||
            supplied.Count != 1 || string.IsNullOrEmpty(supplied[0])) return false;
        // Hash to fixed-length operands; never compare key text with early-exit equality.
        return CryptographicOperations.FixedTimeEquals(
            SHA256.HashData(Encoding.UTF8.GetBytes(expected)),
            SHA256.HashData(Encoding.UTF8.GetBytes(supplied[0]!)));
    }
}
