param([Parameter(Mandatory)][ValidateSet('dev','test','prod')][string]$Stage,[Parameter(Mandatory)][string]$OutputPath)
$ErrorActionPreference='Stop'
$Stage=$Stage.ToLowerInvariant()
$target=& (Join-Path $PSScriptRoot 'Get-RelayReleaseTarget.ps1') -Stage $Stage -ValidateControl
if($env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$'){throw 'Invalid stage run identity.'}
$json=& gh api "repos/$($target.Repository)/actions/runs/$env:GITHUB_RUN_ID/jobs?per_page=100" --paginate --slurp
if($LASTEXITCODE){throw 'Cannot read current stage job identity'}
$jobs=@();foreach($page in (($json -join "`n")|ConvertFrom-Json)){$jobs+=@($page.jobs)}
$job=@($jobs|Where-Object name -CEQ $target.JobName)
if($job.Count -ne 1 -or [string]$job[0].id -notmatch '^[1-9][0-9]*$' -or $job[0].status -cne 'in_progress'){
    throw 'Current fixed deployment job identity is missing/ambiguous.'
}
$blob=@(& git -C (Split-Path $PSScriptRoot) rev-parse "$($env:GITHUB_SHA):$($target.WorkflowPath)")
if($LASTEXITCODE -ne 0 -or $blob.Count -ne 1 -or $blob[0] -notmatch '^[a-f0-9]{40}$'){throw 'Cannot bind control workflow Git blob.'}
$receipt=@{
    schemaVersion=1;stage=$Stage;githubEnvironment=$target.Environment;targetAppResourceId=$target.AppResourceId
    repository=$target.Repository;workflowPath=$target.WorkflowPath;controlCommit=$env:GITHUB_SHA;controlRef=$env:GITHUB_REF
    workflowBlobSha=$blob[0];runId=$env:GITHUB_RUN_ID;jobKey=$target.JobKey;jobName=$target.JobName;jobId=[string]$job[0].id
    package=$target.Package;deploymentAction='completed';acceptance='not awarded by workflow'
}
# Success/independent environment acceptance is established later by API/owner, never this in-progress job.
$bytes=[Text.UTF8Encoding]::new($false).GetBytes(($receipt|ConvertTo-Json -Depth 5))
$stream=[IO.FileStream]::new([IO.Path]::GetFullPath($OutputPath),[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
try{
    $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true);$stream.Position=0
    $observed=[byte[]]::new($bytes.Length);$stream.ReadExactly($observed)
    if($stream.Length -ne $bytes.Length -or [Convert]::ToBase64String($observed) -cne [Convert]::ToBase64String($bytes)){throw 'Stage receipt write verification failed.'}
}finally{$stream.Dispose()}
Write-Output "Created deployment-action receipt for $Stage; owner live acceptance is still required."
