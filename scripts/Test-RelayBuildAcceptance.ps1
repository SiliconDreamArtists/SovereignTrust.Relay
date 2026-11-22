param([Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*$')][string]$BuildRunId,
      [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$ReleaseSha)
$ErrorActionPreference='Stop'
if($env:GITHUB_REPOSITORY -cne 'SiliconDreamArtists/SovereignTrust.Relay' -or
   !$env:RELAY_RELEASE_REF -or $env:RELAY_RELEASE_REF -notmatch '^refs/heads/' -or
   $env:GITHUB_REF -cne $env:RELAY_RELEASE_REF -or $env:GITHUB_SHA -cne $ReleaseSha -or
   $BuildRunId -cne $env:RELAY_ACCEPTED_BUILD_RUN_ID -or
   $env:RELAY_ACCEPTED_BUILD_ARTIFACT_ID -notmatch '^[1-9][0-9]*$' -or
   $env:RELAY_ACCEPTED_BUILD_PACKAGE_SHA256 -notmatch '^[A-Fa-f0-9]{64}$'){
    throw 'Missing/mismatched independently accepted manual build/source contract.'
}
$json=& gh api "repos/$($env:GITHUB_REPOSITORY)/actions/runs/$BuildRunId"
if($LASTEXITCODE){throw 'Cannot read accepted build run'}
$run=($json -join "`n")|ConvertFrom-Json
if($run.repository.full_name -cne $env:GITHUB_REPOSITORY -or
   $run.path -cne '.github/workflows/main_publish_sda-relay-dev.yml' -or
   $run.event -cne 'workflow_dispatch' -or $run.conclusion -cne 'success' -or
   $run.head_sha -cne $ReleaseSha -or ('refs/heads/'+$run.head_branch) -cne $env:RELAY_RELEASE_REF){
    throw 'Accepted build must be successful exact manual package workflow/commit/ref; push/PR cannot deploy.'
}
$json=& gh api "repos/$($env:GITHUB_REPOSITORY)/actions/runs/$BuildRunId/artifacts"
if($LASTEXITCODE){throw 'Cannot read accepted build artifact'}
$artifacts=@((($json -join "`n")|ConvertFrom-Json).artifacts|Where-Object name -CEQ 'relay-manual-package')
if($artifacts.Count -ne 1 -or [string]$artifacts[0].id -cne $env:RELAY_ACCEPTED_BUILD_ARTIFACT_ID -or
   $artifacts[0].expired -or $artifacts[0].workflow_run.head_sha -cne $ReleaseSha){throw 'Missing/expired/mismatched independently accepted artifact ID.'}
Write-Output "Verified accepted manual build $BuildRunId artifact $($artifacts[0].id); downloaded package hash must match before Azure login."
