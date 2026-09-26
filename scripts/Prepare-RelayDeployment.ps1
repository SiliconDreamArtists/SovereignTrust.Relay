param(
    [Parameter(Mandatory)][ValidateSet('sda-relay-dev', 'bddb-sda-prod-relay')][string]$AppName,
    [string]$ResourceGroup,
    [string]$Subscription
)
$ErrorActionPreference = 'Stop'
function Invoke-AzureJson {
    param([string[]]$Arguments)
    if ($Subscription) { $Arguments += @('--subscription', $Subscription) }
    $result = & az @Arguments --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure command failed. Verify deployment identity permissions and app configuration.' }
    if ($result) { ($result -join [Environment]::NewLine) | ConvertFrom-Json }
}
if ($ResourceGroup) {
    $app = Invoke-AzureJson -Arguments @('functionapp', 'show', '--name', $AppName, '--resource-group', $ResourceGroup)
} else {
    $apps = @(Invoke-AzureJson -Arguments @('functionapp', 'list'))
    $app = $apps | Where-Object name -eq $AppName
    if (@($app).Count -ne 1) { throw "Cannot uniquely find $AppName in the selected subscription." }
}
$group = $app.resourceGroup
$detail = Invoke-AzureJson -Arguments @('resource', 'show', '--ids', $app.id)
# The CLI's flattened functionapp response can omit state for Flex apps.
# Prefer the raw ARM resource property, falling back to the CLI value.
$state = [string]$detail.properties.state
if ([string]::IsNullOrWhiteSpace($state)) { $state = [string]$app.state }
if ([string]::IsNullOrWhiteSpace($state)) {
    Write-Output "Deployment target: $($app.id); state: unknown"
    Write-Warning 'Azure did not return an app state; continuing with deployment validation.'
} else {
    Write-Output "Deployment target: $($app.id); state: $state"
    if ($state -ne 'Running') { throw "Azure reports '$state' for $AppName. Start the app before deploying." }
}
$config = Invoke-AzureJson -Arguments @('functionapp', 'config', 'show', '--name', $AppName, '--resource-group', $group)
$runtime = $detail.properties.functionAppConfig.runtime
$relayFlexRuntime = $runtime.name -eq 'dotnet-isolated' -and $runtime.version -eq '10.0'
$relayLinuxRuntime = $config.linuxFxVersion -eq 'DOTNET-ISOLATED|10.0'
$relayWindowsRuntime = $app.kind -notmatch 'linux' -and $config.netFrameworkVersion -eq 'v10.0'
if (!$relayFlexRuntime -and !$relayLinuxRuntime -and !$relayWindowsRuntime) {
    throw 'Configure this app for .NET 10 isolated before deploying.'
}
# Flex runtime metadata already identifies a supported plan. The deployment
# identity can be scoped to the app without read access to its hosting plan.
if (!$relayFlexRuntime) {
    $plan = Invoke-AzureJson -Arguments @('appservice', 'plan', 'show', '--ids', $detail.properties.serverFarmId)
    if ($app.kind -match 'linux' -and $plan.sku.name -eq 'Y1') {
        throw '.NET 10 does not support Linux Consumption. Migrate to a supported plan first.'
    }
}
$settingsList = @(Invoke-AzureJson -Arguments @('functionapp', 'config', 'appsettings', 'list', '--name', $AppName, '--resource-group', $group))
$settings = @{}
foreach ($item in $settingsList) { $settings[$item.name] = $item.value }
if (!$relayFlexRuntime -and $settings.FUNCTIONS_WORKER_RUNTIME -ne 'dotnet-isolated') {
    throw 'Set FUNCTIONS_WORKER_RUNTIME=dotnet-isolated before deployment.'
}
if (!$settings.DISCORD_PUBLIC_KEY -or !$settings.StorageQueueAccount) {
    throw 'Set DISCORD_PUBLIC_KEY and StorageQueueAccount before deployment.'
}
# Never emit the settings or the storage connection string to workflow logs.
$previousConnection = $env:AZURE_STORAGE_CONNECTION_STRING
try {
    $env:AZURE_STORAGE_CONNECTION_STRING = $settings.StorageQueueAccount
    $queue = if ($settings.DISCORD_QUEUE_NAME) { $settings.DISCORD_QUEUE_NAME } else { 'discord-interactions' }
    $container = if ($settings.DISCORD_DEDUP_CONTAINER) { $settings.DISCORD_DEDUP_CONTAINER } else { 'discord-interaction-receipts' }
    $null = Invoke-AzureJson -Arguments @('storage', 'queue', 'create', '--name', $queue)
    $null = Invoke-AzureJson -Arguments @('storage', 'container', 'create', '--name', $container, '--public-access', 'off')
} finally { $env:AZURE_STORAGE_CONNECTION_STRING = $previousConnection }
$null = Invoke-AzureJson -Arguments @('functionapp', 'config', 'appsettings', 'set', '--name', $AppName,
    '--resource-group', $group, '--settings', 'ENABLE_ED25519_SIGNING=false')
Write-Output "Prepared $AppName; test signing is disabled."
