$ErrorActionPreference='Stop'
$root=Join-Path $PSScriptRoot '../..'
$count=0
function Assert-Contract([bool]$Condition,[string]$Name){if(!$Condition){throw "FAIL $Name"};$script:count++;Write-Output "PASS $Name"}
$p=Join-Path $root '.github/workflows/manual_deploy_sda-relay.yml'
$text=Get-Content -Raw $p
Assert-Contract ($text -match '(?m)^  workflow_dispatch:' -and $text -notmatch '(?m)^  (push|pull_request|schedule):') 'Only manual deployment event'
Assert-Contract (@([regex]::Matches($text,'(?m)^      [a-z_]+:$')).Count -eq 1 -and $text.Contains('type: choice') -and $text.Contains('options: [dev, test, prod]')) 'Exactly one fixed environment dropdown'
Assert-Contract (!$text.Contains('release_sha:') -and !$text.Contains('previous_run_id:') -and !$text.Contains('build_run_id:') -and !$text.Contains('enable:')) 'No arbitrary source target or bypass inputs'
Assert-Contract ($text -notmatch 'RELAY_CONTROL_COMMIT|RELAY_PREVIOUS_ACCEPTED_(RECEIPT|PACKAGE)_SHA256|OwnerPacketSha256|BindingSha256') 'No manual deployment hash prerequisite wiring'
foreach($stage in @('dev','test','prod')){
    $block=[regex]::Match($text,'(?ms)^  deploy_'+$stage+':\r?\n(?<body>.*?)(?=^  deploy_|\z)').Groups['body'].Value
    Assert-Contract ($block.Contains("name: Relay deployment $stage") -and $block.Contains("environment: sda-$stage") -and $block.Contains("app-name: sda-relay-api-$stage")) "$stage fixed job environment and target"
    Assert-Contract ($block.Contains("if: `${{ false && inputs.environment == '$stage' }}") -and !$block.Contains('||')) "$stage literal false cannot be enabled by variables"
    Assert-Contract ($block.Contains('Test-RelayBuildAcceptance.ps1') -and $block.Contains('Test-RelayPackage.ps1') -and $block.IndexOf('Test-RelayPackage.ps1') -lt $block.IndexOf('azure/login@v2')) "$stage accepted original bytes before login"
    Assert-Contract (!$block.Contains('dotnet ') -and !$block.Contains('New-RelayPackage.ps1') -and $block.Contains('run-id: 44994573298') -and $block.Contains('artifact-ids: 14743586651') -and $block.Contains('merge-multiple: true')) "$stage never rebuilds accepted artifact"
    Assert-Contract ($block.Contains('New-RelayStageReceipt.ps1 -Stage '+$stage) -and $block.Contains('name: relay-stage-'+$stage)) "$stage fixed receipt artifact"
    if($stage -ne 'dev'){Assert-Contract ($block.Contains('Test-RelayPromotion.ps1 -Stage '+$stage+' -ScratchDirectory') -and !$block.Contains('-ReceiptPath') -and !$block.Contains('path: ${{ runner.temp }}/predecessor') -and $block.IndexOf('Test-RelayPromotion.ps1') -lt $block.IndexOf('azure/login@v2')) "$stage authenticated predecessor proof before login"}
}
foreach($old in @('manual_deploy_sda-relay-dev.yml','manual_deploy_sda-relay-test-main.yml','manual_deploy_sda-relay-prod-main.yml')){Assert-Contract (!(Test-Path (Join-Path $root ".github/workflows/$old"))) "Retired source path $old"}
$ci=Get-Content -Raw (Join-Path $root '.github/workflows/main_publish_sda-relay-dev.yml')
Assert-Contract ($ci -match '(?m)^  push:' -and !$ci.Contains('branches:') -and !$ci.Contains('azure/login') -and !$ci.Contains('webapps-deploy')) 'CI/package build remains nondeployment'
Assert-Contract ($ci.Contains("'relay-manual-package' || 'relay-ci-linux-package'") -and $ci.Contains('retention-days: 30')) 'Manual and build-only artifacts remain distinct'
$legacy=Get-Content -Raw (Join-Path $root '.github/workflows/main_publish_bddb-sda-prod-relay.yml')
Assert-Contract (!$legacy.Contains('azure/login') -and !$legacy.Contains('webapps-deploy') -and $legacy.Contains('exit 1')) 'Legacy remains reject-only'
Assert-Contract (@(Get-ChildItem (Join-Path $root '.github/workflows') -File|Where-Object{(Get-Content -Raw $_.FullName).Contains('azure/webapps-deploy@')}).Count -eq 1) 'Exactly one deployment workflow source path'
Write-Output "Workflow contracts: $count passed"
