# SovereignTrust.Relay

⚡ Serverless relay functions for SovereignTrust.  
Receives external messages (e.g., Discord Interactions), validates them, and wraps them as verifiable [`Signal`](https://github.com/SiliconDreamArtists/signal-core) objects for trustless queue-based execution.

---

## 📡 Current Status

> ✅ **Discord Integration via Azure Function** is live  
> Other hosts and platforms (e.g., Slack, AWS Lambda, Kestrel) may be added per community requirements.

This repo currently implements:

- `DiscordRelayFunction.cs` — Azure Function that handles Discord Interactions Webhook
- `SignalEnqueuer.cs` — Queues wrapped Signal objects to SovereignTrust execution queues
- `SignatureVerifier.cs` — Validates Ed25519 signatures from Discord

---

## 📦 Project Layout

```
SovereignTrust.Relay/
├── hosts/
│   └── azure/
│       ├── DiscordRelayFunction.cs
│       ├── SovereignTrust.Relay.Azure.csproj
├── shared/
│   ├── SignalEnqueuer.cs
│   └── SignatureVerifier.cs
├── tests/
│   └── RelayTests.cs
├── README.md
├── host.json
└── local.settings.json (example config)
```

---

## 🧭 How It Works

1. A Discord user triggers a slash command (`/gpt`, etc.)
2. Discord sends a signed webhook to your Azure Function
3. The relay:
   - Validates the Ed25519 signature
   - Wraps the payload in a standard [`Signal`](https://github.com/SovereignTrust/signal-core) object
   - Pushes it into a queue for SovereignTrust-based processing
4. Your downstream agents consume, verify, and execute the Signal

---

## 🚀 Running Locally

1. Set your Discord public key in `local.settings.json`:
```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet",
    "DiscordPublicKey": "<your-discord-public-key>",
    "SignalQueueUrl": "<your-queue-url>"
  }
}
```

2. Start the Azure Function locally:
```bash
func start
```

3. Use a tool like ngrok to expose your function endpoint:
```bash
ngrok http 7071
```

4. Set the Interactions Endpoint URL in the [Discord Developer Portal](https://discord.com/developers/applications)

---

## 🔐 Signature Verification

Discord sends every interaction signed with Ed25519.  
This function uses your app’s public key (from the developer portal) to:
- Validate `X-Signature-Ed25519`
- Validate `X-Signature-Timestamp`

If either fails, the function returns `401 Unauthorized`.

---

## 🌱 Future Support (Planned)

| Platform | Status |
|----------|--------|
| Discord (Azure Function) | ✅ Implemented |
| Slack (AWS Lambda) | ⏳ Planned |
| Matrix | 🧠 Concept |
| GitHub Webhooks | 🧠 Concept |
| Self-hosted relay | 🧠 Concept |

---

## 📜 License

MIT.  
All relay implementations use the open-source [`Signal-Core`](https://github.com/SiliconDreamArtists/signal-core) format and are part of the [SovereignTrust protocol suite](https://SovereignTrust.foundation).

---

## 🧠 About SovereignTrust

**SovereignTrust** is an open protocol for decentralized, trust-minimized execution of intent.  
Agents speak in `Signal` objects. Relays deliver them.  
No platforms. No middlemen. Just verifiable coordination.

Built by the [Silicon Dream Artists](https://sda.studio).
