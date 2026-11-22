param([Parameter(Mandatory)][ValidateSet('dev','test','prod')][string]$Stage,[string]$ReceiptPath)
$ErrorActionPreference='Stop'
$Stage=$Stage.ToLowerInvariant()
$target=& (Join-Path $PSScriptRoot 'Get-RelayReleaseTarget.ps1') -Stage $Stage -ValidateControl
if(!$target.Predecessor){Write-Output 'Dev has no predecessor; exact accepted manual package is required.';return}
$previous=& (Join-Path $PSScriptRoot 'Get-RelayReleaseTarget.ps1') -Stage $target.Predecessor
$runId=$env:RELAY_PREVIOUS_ACCEPTED_RUN_ID;$artifactId=$env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID
if($runId -notmatch '^[1-9][0-9]*$' -or $artifactId -notmatch '^[1-9][0-9]*$' -or
   $env:RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256 -notmatch '^[A-Fa-f0-9]{64}$' -or
   $env:RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256 -ine $target.Package.Sha256 -or !$ReceiptPath -or !(Test-Path -LiteralPath $ReceiptPath)){
    throw 'Missing owner-accepted predecessor run/artifact/receipt/package.'
}
if((Get-FileHash -LiteralPath $ReceiptPath -Algorithm SHA256).Hash -ine $env:RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256){throw 'Owner-pinned predecessor receipt bytes changed.'}
$receipt=Get-Content -Raw -LiteralPath $ReceiptPath|ConvertFrom-Json
foreach($field in @('stage','githubEnvironment','targetAppResourceId','repository','workflowPath','controlCommit','controlRef','workflowBlobSha','runId','jobKey','jobName','jobId','deploymentAction')){
    if($receipt.$field -isnot [string]){throw "Predecessor receipt field must be scalar text: $field"}
}
if($receipt.schemaVersion -ne 1 -or $receipt.stage -cne $previous.Stage -or $receipt.githubEnvironment -cne $previous.Environment -or
   $receipt.targetAppResourceId -ine $previous.AppResourceId -or $receipt.repository -cne $target.Repository -or
   $receipt.workflowPath -cne $target.WorkflowPath -or $receipt.runId -cne $runId -or
   $receipt.jobKey -cne $previous.JobKey -or $receipt.jobName -cne $previous.JobName -or
   $receipt.jobId -notmatch '^[1-9][0-9]*$' -or $receipt.controlCommit -cnotmatch '^[a-f0-9]{40}$' -or
   $receipt.workflowBlobSha -cnotmatch '^[a-f0-9]{40}$' -or $receipt.controlRef -notmatch '^refs/heads/' -or
   $receipt.deploymentAction -cne 'completed') {throw 'Predecessor stage/job/target/control identity mismatch.'}
foreach($key in $target.Package.Keys){if($receipt.package.$key -cne $target.Package[$key]){throw "Predecessor package tuple changed: $key"}}
$json=& gh api "repos/$($target.Repository)/actions/runs/$runId"
if($LASTEXITCODE){throw 'Cannot read predecessor run'}
$run=($json -join "`n")|ConvertFrom-Json
if($run.repository.full_name -cne $target.Repository -or $run.path -cne $target.WorkflowPath -or $run.event -cne 'workflow_dispatch' -or
   $run.status -cne 'completed' -or $run.conclusion -cne 'success' -or $run.head_sha -cne $receipt.controlCommit -or
   ('refs/heads/'+$run.head_branch) -cne $receipt.controlRef){throw 'Predecessor is not the owner-accepted completed manual control run.'}
$json=& gh api "repos/$($target.Repository)/actions/runs/$runId/artifacts"
if($LASTEXITCODE){throw 'Cannot read predecessor artifact'}
$artifacts=@((($json -join "`n")|ConvertFrom-Json).artifacts|Where-Object name -CEQ ('relay-stage-'+$previous.Stage))
if($artifacts.Count -ne 1 -or [string]$artifacts[0].id -cne $artifactId -or $artifacts[0].expired -ne $false -or
   $artifacts[0].workflow_run.head_sha -cne $receipt.controlCommit){throw 'Wrong/missing/expired predecessor stage artifact.'}
$json=& gh api "repos/$($target.Repository)/actions/runs/$runId/jobs?per_page=100" --paginate --slurp
if($LASTEXITCODE){throw 'Cannot read predecessor jobs'}
$jobs=@();foreach($page in (($json -join "`n")|ConvertFrom-Json)){$jobs+=@($page.jobs)}
$contract=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Relay.Release.psd1')
foreach($row in $contract.Stages.Values){
    $job=@($jobs|Where-Object name -CEQ $row.JobName)
    $expected=if($row.JobKey -ceq $previous.JobKey){'success'}else{'skipped'}
    if($job.Count -ne 1 -or $job[0].status -cne 'completed' -or $job[0].conclusion -cne $expected){throw 'Successful fixed predecessor stage job is not uniquely established.'}
    if($expected -ceq 'success' -and [string]$job[0].id -cne $receipt.jobId){throw 'Predecessor numeric job identity differs from receipt.'}
}
if(@($jobs|Where-Object {$_.name -like 'Relay deployment *'}).Count -ne 3){throw 'Unexpected deployment job identity.'}
$json=& gh api "repos/$($target.Repository)/contents/$($target.WorkflowPath)?ref=$($receipt.controlCommit)"
if($LASTEXITCODE){throw 'Cannot read predecessor reviewed workflow blob'}
$content=($json -join "`n")|ConvertFrom-Json
if($content.sha -cne $receipt.workflowBlobSha){throw 'Historical control workflow blob mismatch.'}
$yaml=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($content.content))
$pattern='(?ms)^  '+[regex]::Escape($previous.JobKey)+':\r?\n(?<body>.*?)(?=^  [a-zA-Z_][\w-]*:\s*$|\z)'
$block=[regex]::Match($yaml,$pattern).Groups['body'].Value
if(!$block -or $block -notmatch ('(?m)^    name: '+[regex]::Escape($previous.JobName)+'\s*$') -or
   $block -notmatch ('(?m)^    environment: '+[regex]::Escape($previous.Environment)+'\s*$') -or
   $block -notmatch ('app-name: '+[regex]::Escape($previous.AppName)+'\s') -or
   @([regex]::Matches($yaml,'(?m)^    name: '+[regex]::Escape($previous.JobName)+'\s*$')).Count -ne 1){throw 'Historical fixed stage job structure does not match accepted receipt.'}
Write-Output "Verified owner-accepted $($previous.Stage) predecessor for $Stage with exact job/target/control/package proof; no live acceptance awarded here."
