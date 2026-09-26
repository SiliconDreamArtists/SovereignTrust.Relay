# Run with pwsh -File Tests/Deployment/Prepare-RelayDeployment.Tests.ps1.
# All Azure calls are mocked; no login, network, or Azure resources are needed.
$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot '../../scripts/Prepare-RelayDeployment.ps1'
$relayDeploymentFixture = @{}
function az {
    $global:LASTEXITCODE = 0
    $command = $args -join ' '
    if ($command -notmatch '--subscription test-sub') { throw 'Subscription missing' }
    if ($command -match '^functionapp show ') {
        if ($command -notmatch '--resource-group sda-dev') { throw 'Resource group missing' }
        @{
            id = '/subscriptions/test-sub/resourceGroups/sda-dev/providers/Microsoft.Web/sites/sda-relay-dev'
            name = 'sda-relay-dev'; resourceGroup = 'sda-dev'; kind = 'functionapp,linux'
            state = $relayDeploymentFixture.CliState
        } | ConvertTo-Json
    } elseif ($command -match '^resource show ') {
        @{properties = @{
            state = $relayDeploymentFixture.ArmState
            functionAppConfig = @{runtime = @{name = 'dotnet-isolated'; version = '10.0'}}
        }} | ConvertTo-Json -Depth 6
    } elseif ($command -match '^functionapp config show ') {
        '{}'
    } elseif ($command -match '^functionapp config appsettings list ') {
        @(@{name = 'DISCORD_PUBLIC_KEY'; value = 'test-key'},
          @{name = 'StorageQueueAccount'; value = 'test-connection'}) | ConvertTo-Json
    } elseif ($command -match '^storage (queue|container) create ') {
        $relayDeploymentFixture.Mutations++
        '{"created":true}'
    } elseif ($command -match '^functionapp config appsettings set ' -and
              $command -match 'ENABLE_ED25519_SIGNING=false') {
        $relayDeploymentFixture.Mutations++
        '[]'
    } else {
        throw "Unexpected Azure operation: $command"
    }
}
$cases = @(
    @{Name = 'Blank CLI state with Running ARM state'; CliState = $null; ArmState = 'Running'; Reject = $false},
    @{Name = 'ARM state overrides CLI state'; CliState = 'Running'; ArmState = 'Stopped'; Reject = $true},
    @{Name = 'Fallback to CLI Running state'; CliState = 'Running'; ArmState = $null; Reject = $false},
    @{Name = 'Fallback to CLI Stopped state'; CliState = 'Stopped'; ArmState = $null; Reject = $true},
    @{Name = 'Missing states are unknown, not stopped'; CliState = ''; ArmState = $null; Reject = $false}
)
foreach ($case in $cases) {
    $relayDeploymentFixture.CliState = $case.CliState
    $relayDeploymentFixture.ArmState = $case.ArmState
    $relayDeploymentFixture.Mutations = 0
    $failure = $null
    $messages = @()
    try {
        $messages = @(& $target -AppName sda-relay-dev -ResourceGroup sda-dev -Subscription test-sub 3>&1)
    } catch { $failure = $_.Exception.Message }
    if ($case.Reject) {
        if ($failure -ne "Azure reports 'Stopped' for sda-relay-dev. Start the app before deploying." -or
            $relayDeploymentFixture.Mutations -ne 0) { throw "FAIL: $($case.Name): $failure" }
    } else {
        if ($failure -or $relayDeploymentFixture.Mutations -ne 3) { throw "FAIL: $($case.Name): $failure" }
        if (!$case.CliState -and !$case.ArmState -and
            !($messages | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })) {
            throw 'Missing state must emit a warning.'
        }
    }
    Write-Output "PASS: $($case.Name)"
}