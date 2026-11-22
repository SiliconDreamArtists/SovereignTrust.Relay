param([Parameter(Mandatory)][ValidateSet('Test','Prod')][string]$Environment,
      [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string]$PreviousRunId,
      [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$ReleaseSha)
$ErrorActionPreference='Stop'
$expected=if($Environment -eq 'Test'){'.github/workflows/manual_deploy_sda-relay-dev.yml'}else{'.github/workflows/manual_deploy_sda-relay-test-main.yml'}
if($env:GITHUB_REPOSITORY -cne 'SiliconDreamArtists/SovereignTrust.Relay' -or !$env:RELAY_RELEASE_REF -or
   $env:GITHUB_REF -cne $env:RELAY_RELEASE_REF -or $env:GITHUB_SHA -cne $ReleaseSha){throw 'Repository/ref/release identity mismatch'}
if($PreviousRunId -cne $env:RELAY_PREVIOUS_ACCEPTED_RUN_ID -or $env:RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$'){
    throw 'Owner must bind the independently accepted previous environment run/package before promotion.'
}
$json=& gh api "repos/$($env:GITHUB_REPOSITORY)/actions/runs/$PreviousRunId"
if($LASTEXITCODE){throw 'Cannot read promotion source'}
$run=($json -join "`n")|ConvertFrom-Json
if($run.repository.full_name -cne $env:GITHUB_REPOSITORY -or $run.path -cne $expected -or
   $run.event -cne 'workflow_dispatch' -or $run.conclusion -cne 'success' -or $run.head_sha -cne $ReleaseSha -or
   ('refs/heads/'+$run.head_branch) -cne $env:RELAY_RELEASE_REF){throw 'Predecessor is not the successful matching environment manual release.'}
$json=& gh api "repos/$($env:GITHUB_REPOSITORY)/actions/runs/$PreviousRunId/artifacts"
if($LASTEXITCODE){throw 'Cannot read predecessor artifacts'}
$artifacts=@((($json -join "`n")|ConvertFrom-Json).artifacts|Where-Object name -CEQ 'relay-release')
if($artifacts.Count -ne 1 -or $artifacts[0].expired -or $artifacts[0].workflow_run.head_sha -cne $ReleaseSha){throw 'Missing/expired/mismatched predecessor artifact'}
Write-Output "Artifact ID $($artifacts[0].id), predecessor run $PreviousRunId"
Write-Output "Verified predecessor $PreviousRunId for $Environment, exact release $ReleaseSha"
