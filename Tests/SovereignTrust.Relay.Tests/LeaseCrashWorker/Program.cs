using Azure.Storage.Blobs;
using SovereignTrust.Relay.Azure.Azure.Discord;

// Isolated Azurite only; parent owns container/ID and deliberately kills this process to test lease recovery.
if (args.Length != 2 || !args[0].StartsWith("receipts-", StringComparison.Ordinal)) return 2;
var container = new BlobContainerClient("UseDevelopmentStorage=true", args[0]);
var receipt = await new BlobReceiptStore(container).AcquireAsync(args[1], default);
if (receipt is null) return 3;
Console.WriteLine("acquired"); Console.Out.Flush();
await Task.Delay(Timeout.Infinite);
GC.KeepAlive(receipt);
return 0;
