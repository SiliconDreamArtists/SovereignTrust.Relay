using System.Text.RegularExpressions;
using Microsoft.Extensions.Configuration;
using NSec.Cryptography;
namespace SovereignTrust.Relay.Azure;

public sealed record RelaySettings(string PublicKey, string StorageAccountName, string QueueName,
    string DedupContainer, bool SigningEnabled, string? TestPrivateKey, string? HelperApiKey = null)
{
    public Uri QueueUri => new($"https://{StorageAccountName}.queue.core.windows.net/{QueueName}");
    public Uri ContainerUri => new($"https://{StorageAccountName}.blob.core.windows.net/{DedupContainer}");

    public static RelaySettings Load(IConfiguration config)
    {
        var publicKey = Required(config, "DISCORD_PUBLIC_KEY");
        try { NSec.Cryptography.PublicKey.Import(SignatureAlgorithm.Ed25519, Convert.FromHexString(publicKey), KeyBlobFormat.RawPublicKey); }
        catch (Exception ex) when (ex is FormatException or ArgumentException)
        { throw new InvalidOperationException("DISCORD_PUBLIC_KEY must be a raw Ed25519 public key in hex."); }
        var account = Required(config, "DISCORD_STORAGE_ACCOUNT_NAME");
        if (!Regex.IsMatch(account, @"\A[a-z0-9]{3,24}\z"))
            throw new InvalidOperationException("DISCORD_STORAGE_ACCOUNT_NAME must be a valid Azure storage account name.");
        var queue = Required(config, "DISCORD_QUEUE_NAME");
        var container = Required(config, "DISCORD_DEDUP_CONTAINER");
        foreach (var (name, value) in new[] { ("DISCORD_QUEUE_NAME", queue), ("DISCORD_DEDUP_CONTAINER", container) })
            if (!Regex.IsMatch(value, @"\A[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]\z"))
                throw new InvalidOperationException($"{name} must be a valid Azure storage resource name.");
        var enabled = bool.TryParse(config["ENABLE_ED25519_SIGNING"], out var flag) && flag;
        string? privateKey = null;
        string? helperKey = null;
        if (enabled)
        {
            helperKey = Required(config, "RELAY_HELPER_API_KEY");
            privateKey = Required(config, "DISCORD_TEST_PRIVATE_KEY");
            try { using var key = Key.Import(SignatureAlgorithm.Ed25519, Convert.FromHexString(privateKey), KeyBlobFormat.RawPrivateKey); }
            catch (Exception ex) when (ex is FormatException or ArgumentException)
            { throw new InvalidOperationException("DISCORD_TEST_PRIVATE_KEY must be a raw Ed25519 private key in hex."); }
        }
        return new(publicKey, account, queue, container, enabled, privateKey, helperKey);
    }
    private static string Required(IConfiguration config, string name) =>
        !string.IsNullOrWhiteSpace(config[name]) ? config[name]! :
        throw new InvalidOperationException($"Required setting {name} is missing.");
}
