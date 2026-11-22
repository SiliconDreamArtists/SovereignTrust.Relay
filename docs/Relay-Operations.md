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
pwsh -NoProfile -File Tests/Deployment/Release-Workflow.Tests.ps1 -EvidenceDirectory Documentation/Projects/Working/logs/local-release-fixtures
pwsh -NoProfile -File Tests/Deployment/Package-Promotion.Tests.ps1 -EvidenceDirectory Documentation/Projects/Working/logs/local-package-fixtures
```

Full suite hard-codes UseDevelopmentStorage=true and uses pinned Azurite3.35.0 on localhost10000/10001, isolated disposable resources. RELAY_TEST_STORAGE is ignored, including remote-looking inherited values; test clients cannot select a cloud endpoint. Recovery child deliberately crashes while holding an isolated lease and verifies expiry/restart. Never substitute live storage. Inspect listeners before starting; stop only owned process. Run full dotnet test without filter. Test-results/logs belong under Documentation/Projects/Working/logs with unique run paths.

Linux build-only CI runs on pushes to any branch and PRs without Azure login/deployment. It tests pinned storage, builds a committed clean snapshot, verifies package hash/manifest and starts actual published Kestrel with disposable config. Windows checks cannot establish Linux native-crypto/package acceptance. Automatic push/PR packages are explicitly build-only, with branch/PR merge refs validated in a nondeployment mode; retained relay-ci-linux-package cannot deploy. A separately authorized workflow_dispatch on this same build workflow creates manual-origin deployment-release bytes in distinctly named relay-manual-package. Both retain ZIP, source/build manifest and published-host evidence for at least30 days, plus immutable artifact ID/digest and run/commit identity; TRX/adverse startup receipts are retained. Independent review must accept exact manual package/run/artifact/hash before Dev deployment. No build workflow logs into Azure or deploys. A missing actual Linux receipt remains pending.

## Release and owner host contract

Proposed globally available names at planning observation (not reservations): sda-relay-api-dev, sda-relay-api-test, sda-relay-api-prod. Owner must create exact separate apps on existing ASP-sda-dev-fusion B1, ASP-sda-test-fusion B1 and unchanged ASP-sda-prod-fusion B3. Dev/Test observed F1 require owner separately reviewed upgrade first. New app IDs/system MI/default hosts are creation outputs. Never mutate Fusion/Conductor apps, identities or production fusionst TLS through Relay scripts.

The source deployment interface is ONE workflow, [Deploy Relay](../.github/workflows/manual_deploy_sda-relay.yml), with one environment choice dev|test|prod. Do not type a commit, run, hostname or target. All three fixed deployment jobs have literal-false guards. They cannot be enabled by an input or variable. Current authorization forbids dispatch and cloud effects. Removing a guard needs a separately reviewed exact owner packet and independent live READY; merely filling settings is insufficient.

The three old per-environment deployment YAMLs are removed from this branch. Default main still has historical Test/Prod Actions definitions; branch source publication does not retire their default UI. No default-main merge or remote workflow-state change is included here, and none may be dispatched now. The separate build/test/package workflow stays nondeployment; legacy Function promotion remains disabled/reject-only; link checks remain diagnostic.

The fixed public [release contract](../scripts/Relay.Release.psd1) maps choices to sda-dev/sda-test/sda-prod and the matching subscription/RG/new Relay app/existing Fusion plan. It records app-only environment federation subjects and exact tenant, with deployment client/principal, runtime MI, default host and actual owner packet bindings explicitly unset. Missing/cross-environment metadata fails closed before Azure login. Owner alone provisions hosts, Dev/Test B1 upgrades, per-app Always On/runtime/HTTPS/SCM, app-only UAMI/FIC/RBAC and secret references. Never copy a connection-string/secret value into Terraform config/variables/plans/state/outputs/logs; value migration stays outside Terraform under separate reviewed owner procedure. Terraform receives nonsecret Key Vault-reference metadata and exact runtime-MI secret-read binding, no generic Storage roles. An owner document hash is not an executable packet or proof these outputs exist.

Accepted bytes stay exactly manual run44994573298/artifact14743586651, ZIP SHA256 E4473862F6A6406B8DC021CFFCB34B82247AAD7640D9FE0CB3659D1A8DBB87FC, source b32c3fbfe2cdf64056be264d59dcd97df6d4591e. The build source/ref and new reviewed workflow control commit/ref are distinct: workflow edits never rebuild or rewrite this ZIP/manifest. All stages download that exact artifact ID, check original manual run/source/tree/wrapper/package/file hashes and promote the same bytes. Expired/missing artifact stops; no automatic replacement. Artifact expiry is2026-12-22T06:38:46Z; owner must preserve accepted bytes for campaign/rollback duration through a separately verified retention route if needed.

The normal Actions branch selector is rejected unless it matches the fixed reviewed control ref. Each selected protected GitHub environment must eventually bind RELAY_CONTROL_COMMIT to the independently reviewed control revision, and RELAY_AZURE_CLIENT_ID/TENANT_ID/SUBSCRIPTION_ID to its fixed owner profile. These are identity checks, never enablement flags. No environment variables, policies or federation settings are changed in this source phase.

Dev requires the accepted package and complete control/owner profile. Test additionally requires independently owner-accepted Dev; Prod requires independently owner-accepted Test. Caller supplies no predecessor run. Owner pointers are RELAY_PREVIOUS_ACCEPTED_RUN_ID, RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID, RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256 and RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256. Missing pointers/receipt fail before login. Populate them only after independent actual environment acceptance, never solely because an Action is green.

Each static job writes relay-stage-dev/test/prod deployment-action receipt while its own job is in_progress and uploads it with immutable artifact identity. File creation uses CreateNew/exclusive sharing and verifies the bytes before releasing the handle; an existing receipt cannot be overwritten. Receipt does not award environment acceptance. Subsequent promotion independently verifies the completed-success run and unique correct fixed job ID/name, skipped other stage jobs, owner-pinned artifact/receipt digest, exact target and original package, plus historical control commit/ref/workflow blob. A Test run under the same workflow path cannot masquerade as Dev. Historical stage control revision can differ from current control and package source only through this exact accepted proof.

Default-host/deadline/signature/queue/receipt/consumer/callback/capacity/rollback acceptance remains separate from deployment action completion. Real interactions can cause Discord follow-ups; no production queue/callback test without reviewed bounded fixture and cleanup. Discord owns its signing private key: actual ping mechanism must be disposable-app Developer Portal validation, reviewed real-app endpoint change/rollback or legitimate fresh capture/replay safeguards, never signing with a public key. No synthetic fixture establishes live behavior.

Deploy/test default hosts Dev→Test→Prod before any traffic switch. Dev canonical name remains dev.discord.relay.sda.studio; Test name unresolved; legacy dev.relay.sda.studio needs deliberate disposition. Owner controls trusted TLS/asuid/coexistence or bounded outage, exact DNS forward/inverse/cutover, numeric shared-plan/callback safety and no-consumer retirement gate. Keep old Functions/packages/settings/queues/receipts/callers live until accepted replacement/retirement. Source-only acceptance does not establish full live migration.

Rollback reinstalls exact prior accepted package/settings and reverses captured client/Discord URL/DNS type/target/TTL/bindings/certs, checking trusted TLS/DNS/safe consumer behavior. No slots, receipt deletion or blind DNS flipping. Unknown/partial state stops effects. Post-delete recovery needs recreation+identity+roles+package+cert/domain+client+state, not DNS alone.
