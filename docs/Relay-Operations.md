# Relay operations

Relay is an ordinary ASP.NET Core .NET 10 Web API. The historical project/assembly name remains SovereignTrust.Relay.Azure; no Azure Functions runtime or Function package is used.

## Start and routes

Publish the Web project, then start `dotnet SovereignTrust.Relay.Azure.dll` from its publish directory. Use the platform ASPNETCORE_URLS binding; for local work pass `--urls http://127.0.0.1:7107`. App Service runtime is Linux DOTNETCORE|10.0, HTTPS only, Always On enabled on each app. Configure the platform health check path `/healthz`; this reports process readiness and makes no storage call. Always On reduces idle unload, not restart interruption or a latency guarantee. Basic plans have no deployment-slot assumption.

| Method/path | Contract |
| --- | --- |
| POST /api/discordrelay | Public ingress, mandatory Discord Ed25519 signature; valid signed ping responds type1 without storage. Types2/3/5 enqueue then respond type5. |
| POST /api/Ed25519SignFunction | Disabled404 by default; enabled local/test-only signer additionally requires x-functions-key. |
| GET /api/GenerateEd25519KeyPair | Same flag/key boundary; returns a newly generated disposable test key only. |
| GET /healthz | Shallow process readiness; proves neither queue access nor callback integration. |

Unknown paths return404; wrong methods405. `/api/discord` is not an advertised route. Existing callers using it must be inventoried/migrated explicitly, not silently assumed compatible. No global host login may intercept Discord verification.

## Settings and isolation

| Setting | Requirement |
| --- | --- |
| DISCORD_PUBLIC_KEY | Required real application's raw Ed25519 hex public key; use the matching environment's Discord app. |
| StorageQueueAccount | Required Queue+Blob connection, delivered through an owner-managed Key Vault reference for live hosts; never copy values to source/state/logs. |
| DISCORD_QUEUE_NAME | Explicit live owner binding; local default discord-interactions. |
| DISCORD_DEDUP_CONTAINER | Explicit private live container; local default discord-interaction-receipts. Preserve existing receipts. |
| ENABLE_ED25519_SIGNING | Set exactly false on every released host. Missing/invalid/false disables both helpers. |
| RELAY_HELPER_API_KEY | Required only if helper enabled; separate test-only secret, never an implicitly copied Function host key. |
| DISCORD_TEST_PRIVATE_KEY | Required only if helper enabled; test-only raw Ed25519 hex. |

DISCORD_PRIVATE_KEY is never read. Owner inventories/rotates/removes obsolete secret only through its separate reviewed operation; migration does not copy it. Startup validates syntax without contacting storage. Missing/invalid required settings fail startup with setting name, never value. Each environment needs its own key/app, storage credentials, queue/receipt boundary, managed identity/vault access, consumers and callback destinations. A shared default name does not establish isolation. No test request may accidentally target production queue or callback.

When explicitly used locally, enabled helpers require exactly one valid x-functions-key header; missing/wrong/multiple keys401, query `code` unsupported. Disabled routes404 before helper auth. The signer never returns configured private key; key generation returns its new private key intentionally, so use only disposable local keys and never log its response. Live enablement/keygen tests are outside this migration. Discord signs its own real ping; the helper is unnecessary for Developer Portal verification.

## Storage and failure contract

Owner provisions queue and private receipt container before deployment and verifies vault-reference resolution and data-plane access. No request or deployment preflight creates resources. Preserve actual account/queue/container and consumers through the move; no receipt reset, queue purge, destructive drain or new default fallback.

Signatures accept timestamps up to300 seconds old and30 seconds future. Strict UTF8 input is bounded to65536 decoded characters, serialized Signal to48KiB UTF8. Discord types2/3/5 require positive ulong interaction ID and preserve it as Result.id. Two-second processing budget covers body and storage; cleanup adds at most150ms. SDK retries disabled. Platform scheduling/restart/network can exceed Discord's three-second deadline: measure fresh live latency and shared-plan capacity.

Fifteen-second Blob leases serialize simultaneous handlers across instances. Queue send precedes receipt completion; completed duplicates return deferred response without resend; held lease/unavailable storage/cancellation503. Lease release is bounded and expiration recovers crashes. Receipts contain no payload/token and remain retained; any lifecycle policy is at least seven days.

Queue send and receipt completion are not a transaction. Lost send response or failed completion can enqueue duplicates on retry. Delivery is at least once. Every consuming system must persist Result.id and atomically couple dedup completion with side effects or use destination API idempotency. Relay tests do not establish consumer idempotency. No receipt logic change claims exactly once.

## Local and Linux checks

Use SDK10. Unit/hosted HTTP checks:

```powershell
dotnet test Tests/SovereignTrust.Relay.Tests/SovereignTrust.Relay.Tests.csproj --configuration Release --filter 'Category!=Storage'
pwsh -NoProfile -File Tests/Deployment/Prepare-RelayDeployment.Tests.ps1
pwsh -NoProfile -File Tests/Deployment/Workflow-Contracts.Tests.ps1
```

Full suite hard-codes UseDevelopmentStorage=true and uses pinned Azurite3.35.0 on localhost10000/10001, isolated disposable resources. RELAY_TEST_STORAGE is ignored, including remote-looking inherited values; test clients cannot select a cloud endpoint. Recovery child deliberately crashes while holding an isolated lease and verifies expiry/restart. Never substitute live storage. Inspect listeners before starting; stop only owned process. Run full dotnet test without filter. Test-results/logs belong under Documentation/Projects/Working/logs with unique run paths.

Linux build-only CI runs on pushes to any branch and PRs without Azure login/deployment. It tests pinned storage, builds a committed clean snapshot, verifies package hash/manifest and starts actual published Kestrel with disposable config. Windows checks cannot establish Linux native-crypto/package acceptance. Automatic push/PR packages are explicitly build-only, with branch/PR merge refs validated in a nondeployment mode; retained relay-ci-linux-package cannot deploy. A separately authorized workflow_dispatch on this same build workflow creates manual-origin deployment-release bytes in distinctly named relay-manual-package. Both retain ZIP, source/build manifest and published-host evidence for at least30 days, plus immutable artifact ID/digest and run/commit identity; TRX/adverse startup receipts are retained. Independent review must accept exact manual package/run/artifact/hash before Dev deployment. No build workflow logs into Azure or deploys. A missing actual Linux receipt remains pending.

## Release and owner host contract

Proposed globally available names at planning observation (not reservations): sda-relay-api-dev, sda-relay-api-test, sda-relay-api-prod. Owner must create exact separate apps on existing ASP-sda-dev-fusion B1, ASP-sda-test-fusion B1 and unchanged ASP-sda-prod-fusion B3. Dev/Test observed F1 require owner separately reviewed upgrade first. New app IDs/system MI/default hosts are creation outputs. Never mutate Fusion/Conductor apps, identities or production fusionst TLS through Relay scripts.

All deployment workflows are manual. Old Dev workflow path now builds/tests only; disabled legacy Prod path rejects deployment. Manual link checks are read-only. Remote workflow-state/publication transition remains owner/coordinator controlled; local edits do not disable currently live workflows.

Each GitHub environment sda-dev/sda-test/sda-prod requires these owner-supplied variables:

| Variable | Meaning |
| --- | --- |
| RELAY_RELEASE_REF | Exact allowed refs/heads/... matching reviewed source and GitHub selected-branch policy. |
| RELAY_APP_RESOURCE_ID / RELAY_PLAN_RESOURCE_ID | Exact new ordinary app and existing Fusion plan. |
| RELAY_AZURE_CLIENT_ID / RELAY_AZURE_TENANT_ID / RELAY_AZURE_SUBSCRIPTION_ID | Public OIDC binding for deployment; owner provisions matching FIC and app-scoped RBAC, never subscription Contributor. |
| RELAY_ACCEPTED_BUILD_RUN_ID / RELAY_ACCEPTED_BUILD_ARTIFACT_ID / RELAY_ACCEPTED_BUILD_PACKAGE_SHA256 | Dev only: exact independently accepted manual build run/artifact/package. Missing or mismatched receipt prevents Azure login. |
| RELAY_PREVIOUS_ACCEPTED_RUN_ID / RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256 | Test/Prod only: owner records independently accepted previous-env live receipt after required checks. Workflow action success alone cannot populate acceptance. |

Dispatch selected reviewed ref with release_sha equal to its exact commit. First run the nondeploying build workflow manually; inspect its Linux tests/startup and immutable package, then independently accept exact run/artifact/package. Dev supplies build_run_id, verifies manual workflow/source/ref/artifact identity and downloads that same accepted ZIP without rebuilding. Push/PR build packages are rejected. Test supplies successful Dev previous_run_id; Prod supplies successful Test previous_run_id. Predecessor workflow/repository/manual origin/ref/SHA/conclusion, independently accepted prior run/hash and ZIP manifest are verified before Azure login. Test/Prod promote unchanged bytes and upload same artifact for next stage. Minimum30-day artifacts; extend retention/secure known-good backup for campaign+rollback.

Manual workflow selection may require default-branch publication. Migration-branch deployment needs explicit environment selected-branch/FIC route first. Main-only policy needs separately authorized main publication. Never merge/bypass branch guards/change policies to make a dispatch work. Missing target/ref/OIDC contract fails closed.

The ZIP root contains main DLL/deps/runtimeconfig/native NSec assets and excludes Functions metadata/local settings/secrets. New-RelayPackage refuses tracked dirty source, captures commit/tree/SDK/OS and file/package SHA256. Test-RelayPackage verifies all entries and Linux provenance claim; actual Linux CI receipt supplies runtime evidence. Preflight validates only exact target/runtime/HTTPS/AlwaysOn/config names/signing=false and performs no configuration/storage writes. Owner separately verifies secret reference resolution, queue/receipt continuity and live tests.

Deploy Dev, then Test, then Prod default hosts before changing traffic. New Prod must pass production-specific safe tests before production alias moves away from current Dev origin. Correct Dev name is dev.discord.relay.sda.studio. Test name undecided; legacy dev.relay.sda.studio needs explicit retain/migrate/rollback disposition. Owner controls exact DNS CNAME forward/inverse, TXT/bindings, trusted prebound TLS/coexistence or reviewed bounded outage, callback-safe fixtures/cleanup, numeric capacity/error/latency thresholds and observation window.

Real interactions can trigger real Discord follow-ups; unsigned negatives and signed ping do not prove queue/callback delivery. No production queue/callback test without reviewed fixture and cleanup. No full migration claim until actual consumer persistent idempotency, all env/domain/TLS/callback/rollback/capacity evidence and no-old-consumer disposition independently pass. Keep old Function apps/packages/settings/credentials/bindings live through acceptance. Owner alone may retire old Functions after accepted no-consumer evidence and exact deletion readiness.

Rollback reinstalls exact prior accepted package/settings and reverses captured client/Discord URL/DNS type/target/TTL/bindings/certs, checking trusted TLS/DNS/safe consumer behavior. No slots, receipt deletion or blind DNS flipping. Unknown/partial state stops effects. Post-delete recovery needs recreation+identity+roles+package+cert/domain+client+state, not DNS alone.