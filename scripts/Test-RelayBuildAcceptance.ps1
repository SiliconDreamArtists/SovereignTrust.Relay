param([string]$BuildRunId,[string]$ReleaseSha)
$ErrorActionPreference='Stop'
$target=& (Join-Path $PSScriptRoot 'Get-RelayReleaseTarget.ps1') -Stage dev -ValidateControl
$package=$target.Package
if(($BuildRunId -and $BuildRunId -cne $package.BuildRunId) -or ($ReleaseSha -and $ReleaseSha -cne $package.SourceCommit)){
    throw 'Caller cannot replace the independently accepted package tuple.'
}
$json=& gh api "repos/$($target.Repository)/actions/runs/$($package.BuildRunId)"
if($LASTEXITCODE){throw 'Cannot read accepted manual build'}
$run=($json -join "`n")|ConvertFrom-Json
if($run.repository.full_name -cne $target.Repository -or $run.path -cne $package.BuildWorkflowPath -or
   $run.event -cne 'workflow_dispatch' -or $run.status -cne 'completed' -or $run.conclusion -cne 'success' -or
   $run.head_sha -cne $package.SourceCommit -or ('refs/heads/'+$run.head_branch) -cne $package.SourceRef){
    throw 'Original package manual workflow/source/ref is not the accepted successful build.'
}
$json=& gh api "repos/$($target.Repository)/actions/runs/$($package.BuildRunId)/artifacts"
if($LASTEXITCODE){throw 'Cannot read accepted artifact'}
$artifacts=@((($json -join "`n")|ConvertFrom-Json).artifacts|Where-Object name -CEQ $package.ArtifactName)
if($artifacts.Count -ne 1 -or [string]$artifacts[0].id -cne $package.ArtifactId -or $artifacts[0].expired -ne $false -or
   $artifacts[0].workflow_run.head_sha -cne $package.SourceCommit -or $artifacts[0].digest -ine ('sha256:'+$package.WrapperSha256)){
    throw 'Accepted manual artifact ID/digest/source missing, expired or changed.'
}
Write-Output "Verified fixed manual package source $($package.SourceCommit); deployment control $env:GITHUB_SHA is independently reviewed."
