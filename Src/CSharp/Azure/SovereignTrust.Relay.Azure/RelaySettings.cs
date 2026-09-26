using System.Text.RegularExpressions;
using Azure.Storage.Blobs;
using Azure.Storage.Queues;
using Microsoft.Extensions.Configuration;
using NSec.Cryptography;
namespace SovereignTrust.Relay.Azure;

public sealed record RelaySettings(string PublicKey, string StorageConnection, string QueueName,
    string DedupContainer, bool SigningEnabled, string? TestPrivateKey)
{
    public static RelaySettings Load(IConfiguration config)
    {
        var publicKey = Required(config, "DISCORD_PUBLIC_KEY");
        try { NSec.Cryptography.PublicKey.Import(SignatureAlgorithm.Ed25519, Convert.FromHexString(publicKey), KeyBlobFormat.RawPublicKey); }
        catch (Exception ex) when (ex is FormatException or ArgumentException)
        { throw new InvalidOperationException("DISCORD_PUBLIC_KEY must be a raw Ed25519 public key in hex."); }
        var connection = Required(config, "StorageQueueAccount");
        var queue = config["DISCORD_QUEUE_NAME"] ?? "discord-interactions";
        var container = config["DISCORD_DEDUP_CONTAINER"] ?? "discord-interaction-receipts";
        foreach (var name in new[] { queue, container })
            if (!Regex.IsMatch(name, "^[a-z0-9](?:[a-z0-9]|-(?!-)){1,61}[a-z0-9]$"))
                throw new InvalidOperationException("Queue and receipt container names must be valid Azure storage resource names.");
        try { _ = new QueueClient(connection, queue); _ = new BlobContainerClient(connection, container); }
        catch (Exception ex) when (ex is FormatException or ArgumentException)
        { throw new InvalidOperationException("StorageQueueAccount must be a valid Queue and Blob storage connection string."); }
        var enabled = bool.TryParse(config["ENABLE_ED25519_SIGNING"], out var flag) && flag;
        string? privateKey = null;
        if (enabled)
        {
            privateKey = Required(config, "DISCORD_TEST_PRIVATE_KEY");
            try { using var key = Key.Import(SignatureAlgorithm.Ed25519, Convert.FromHexString(privateKey), KeyBlobFormat.RawPrivateKey); }
            catch (Exception ex) when (ex is FormatException or ArgumentException)
            { throw new InvalidOperationException("DISCORD_TEST_PRIVATE_KEY must be a raw Ed25519 private key in hex."); }
        }
        return new(publicKey, connection, queue, container, enabled, privateKey);
    }
    private static string Required(IConfiguration config, string name) =>
        !string.IsNullOrWhiteSpace(config[name]) ? config[name]! :
        throw new InvalidOperationException($"Required setting {name} is missing.");
}
