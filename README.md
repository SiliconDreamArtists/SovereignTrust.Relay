# SovereignTrust.Relay

**SovereignTrust.Relay** is the ingestion layer of the [SovereignTrust](https://sovereigntrust.foundation) protocol. It accepts external input — including webhooks, HTTP events, and raw messages — and transforms them into valid `Signal<T>` messages for the SovereignTrust queue.

Relays are stateless, lightweight bridges that connect the outside world to the SovereignTrust execution pipeline.

---

## 🧠 Purpose

Relays do not validate, authorize, or execute. They:

- ✅ Receive input from external systems (Discord, GitHub, Web APIs)
- ✅ Optionally wrap or transform the payload into a `Signal<T>`
- ✅ Push structured signals to a trusted queue (e.g. Azure, AWS, Redis)
- ✅ Return minimal HTTP responses for webhook compatibility

---

## 🧱 Architecture

```plaintext
[ External Input (Webhook, API, Event) ]
               ↓
         [ SovereignTrust.Relay ]
               ↓
         [ Queue: SovereignTrust ]
               ↓
         [ Router / Executor Node ]
```

---

## ⚙️ Features

| Feature           | Description                                         |
|------------------|-----------------------------------------------------|
| Webhook Listener | Accepts POST requests and verifies headers          |
| Signal Transformer | Wraps raw input into a structured `Signal<T>`      |
| Queue Writer     | Enqueues to Azure Queue, AWS SQS, or custom adapter |
| Stateless        | Runs as Azure Function, container, or serverless    |

---

## 📤 Example Relay Flow

A Discord interaction is received:
```json
{
  "type": 2,
  "data": {
    "name": "build-dna",
    "options": [ { "name": "template", "value": "DragonAlpha" } ]
  }
}
```

Relay transforms to:
```json
{
  "Name": "DiscordBuildCommand",
  "Result": {
    "command": "build-dna",
    "args": {
      "template": "DragonAlpha"
    }
  },
  "Level": "Information"
}
```

Pushed into SovereignTrust queue for execution.

---

## 🔌 Supported Hosts

| Host Platform | Description                          |
|---------------|--------------------------------------|
| Azure Function | Native support with `HttpTrigger`   |
| AWS Lambda    | Wrap with API Gateway                |
| Kestrel (.NET) | For on-prem or container use        |

Each relay should be small, scoped, and stateless.

---

## 🧩 Extending Relays

- Implement your platform’s HTTP listener
- Use the Signal format spec to wrap messages
- Push to queue with optional metadata enrichments
- Return 200 OK or minimal HTTP JSON response

---

## 🧪 Example Usage

Coming soon in `Examples/DiscordRelay.cs` and `Relay.Tests/`.

---

## 🧠 Design Philosophy

Relays are **connectors, not interpreters**. They ensure structured, verifiable input enters the SovereignTrust system with no opinion about what should be done next.

---

## 📄 License

MIT — see [`LICENSE`](./LICENSE)

---

## 🔗 Related Repos

- [`SovereignTrust.SignalGraph`](https://github.com/SiliconDreamArtists/signal-core) – The universal feedback/result object
- [`SovereignTrust.Router`](https://github.com/SiliconDreamArtists/SovereignTrust.Router) – Resolves and executes signal instructions
- [`SovereignTrust.Emitter`](https://github.com/SiliconDreamArtists/SovereignTrust.Emitter) – Triggers and authors intent signals
