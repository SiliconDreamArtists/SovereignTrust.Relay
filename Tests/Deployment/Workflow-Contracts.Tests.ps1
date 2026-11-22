$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../..'
$count=0
function Assert-Contract([bool]$Condition,[string]$Name){if(!$Condition){throw "FAIL $Name"};$script:count++;Write-Output "PASS $Name"}
foreach($environment in @('dev','test','prod')){
    $suffix=if($environment -eq 'dev'){'dev'}else{"$environment-main"}
    $text=Get-Content -Raw (Join-Path $root ".github/workflows/manual_deploy_sda-relay-$suffix.yml")
    Assert-Contract ($text -match '(?m)^  workflow_dispatch:' -and $text -notmatch '(?m)^  (push|pull_request|schedule):') "$environment manual only"
    Assert-Contract ($text.Contains("environment: sda-$environment") -and $text.Contains("app-name: sda-relay-api-$environment")) "$environment exact environment/app"
    Assert-Contract ($text.Contains('azure/webapps-deploy@v3') -and !$text.Contains('functions-action')) "$environment ordinary deployment"
    Assert-Contract ($text.Contains('RELAY_RELEASE_REF') -and $text.Contains('GITHUB_SHA -cne $env:RELEASE_SHA')) "$environment exact source identity"
    Assert-Contract ($text.Contains('Test-RelayPackage.ps1') -and $text.Contains('Prepare-RelayDeployment.ps1')) "$environment predeployment guards"
    Assert-Contract (!$text.Contains("'`${{ inputs.previous_run_id }}'") -and !$text.Contains("'`${{ inputs.release_sha }}'")) "$environment no input interpolation into script"
    if($environment -ne 'dev'){
        Assert-Contract ($text.Contains('RELAY_PREVIOUS_ACCEPTED_RUN_ID') -and $text.Contains('-AcceptedPackageSha256 $env:RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256')) "$environment accepted predecessor binding"
        Assert-Contract (!$text.Contains('dotnet publish') -and !$text.Contains('New-RelayPackage.ps1')) "$environment promotes without rebuilding"
    }else{
        Assert-Contract (!$text.Contains('dotnet publish') -and !$text.Contains('New-RelayPackage.ps1') -and $text.Contains('name: relay-manual-package')) 'Dev downloads accepted manual package without rebuilding'
        Assert-Contract ($text.Contains('RELAY_ACCEPTED_BUILD_ARTIFACT_ID') -and $text.Contains('-ExpectedBuildRunId $env:BUILD_RUN_ID -AcceptedPackageSha256 $env:RELAY_ACCEPTED_BUILD_PACKAGE_SHA256') -and $text.IndexOf('Test-RelayBuildAcceptance.ps1') -lt $text.IndexOf('azure/login@v2') -and $text.IndexOf('Test-RelayPackage.ps1') -lt $text.IndexOf('azure/login@v2')) 'Dev binds accepted run artifact and bytes before Azure login'
    }
}
$ci=Get-Content -Raw (Join-Path $root '.github/workflows/main_publish_sda-relay-dev.yml')
Assert-Contract ($ci -match '(?m)^  push:' -and !$ci.Contains('branches:') -and !$ci.Contains('azure/login') -and !$ci.Contains('webapps-deploy')) 'CI runs on published migration branch without deployment'
Assert-Contract ($ci.Contains('New-RelayPackage.ps1') -and $ci.Contains('Test-RelayPackage.ps1') -and @([regex]::Matches($ci,'-BuildOnly')).Count -eq 2 -and $ci.Contains("if (`$env:GITHUB_EVENT_NAME -ceq 'workflow_dispatch')")) 'CI selects manual release vs nondeployment push PR mode'
Assert-Contract ($ci.Contains("'relay-manual-package' || 'relay-ci-linux-package'") -and $ci.Contains('relay-package/relay.zip') -and $ci.Contains('relay-package/release.json') -and $ci.Contains('relay-package/host-evidence/') -and $ci.Contains('retention-days: 30')) 'CI retains distinct manual and nondeployment ZIP manifest startup artifacts'
Assert-Contract ($ci.Contains('steps.linux_build_artifact.outputs.artifact-id') -and $ci.Contains('steps.linux_build_artifact.outputs.artifact-digest') -and $ci.Contains('commit=$env:GITHUB_SHA')) 'CI records attributable immutable artifact identity'
$legacy=Get-Content -Raw (Join-Path $root '.github/workflows/main_publish_bddb-sda-prod-relay.yml')
Assert-Contract (!$legacy.Contains('azure/login') -and !$legacy.Contains('functions-action') -and $legacy.Contains('exit 1')) 'Legacy cannot deploy'
Write-Output "Workflow contracts: $count passed"
