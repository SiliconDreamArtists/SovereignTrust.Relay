param([Parameter(Mandatory)][ValidateSet('dev','test','prod')][string]$Stage,
      [Parameter(Mandatory)][string]$ScratchDirectory)
$ErrorActionPreference='Stop'
$target=& (Join-Path $PSScriptRoot 'Get-RelayReleaseTarget.ps1') -Stage $Stage
if(!$target.Predecessor){throw 'Dev has no predecessor receipt.'}
$previous=& (Join-Path $PSScriptRoot 'Get-RelayReleaseTarget.ps1') -Stage $target.Predecessor
$runId=$env:RELAY_PREVIOUS_ACCEPTED_RUN_ID;$artifactId=$env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID
if($runId -notmatch '^[1-9][0-9]*$' -or $artifactId -notmatch '^[1-9][0-9]*$'){throw 'Missing owner-accepted predecessor run/artifact IDs.'}
function Read-RelayApi([string]$Route,[switch]$Pages){
    $json=if($Pages){& gh api $Route --paginate --slurp}else{& gh api $Route}
    if($LASTEXITCODE){throw 'Cannot read predecessor artifact provenance'}
    ($json -join "`n")|ConvertFrom-Json
}
$run=Read-RelayApi "repos/$($target.Repository)/actions/runs/$runId"
if($run.repository.full_name -cne $target.Repository -or $run.path -cne $target.WorkflowPath -or
   $run.event -cne 'workflow_dispatch' -or $run.status -cne 'completed' -or $run.conclusion -cne 'success' -or
   $run.head_sha -cnotmatch '^[a-f0-9]{40}$' -or !$run.head_branch){throw 'Predecessor is not an accepted completed manual run.'}
$artifact=Read-RelayApi "repos/$($target.Repository)/actions/artifacts/$artifactId"
$matches=@();foreach($page in (Read-RelayApi "repos/$($target.Repository)/actions/runs/$runId/artifacts?per_page=100" -Pages)){
    $matches+=@($page.artifacts|Where-Object name -CEQ ('relay-stage-'+$previous.Stage))
}
if($matches.Count -ne 1 -or [string]$matches[0].id -cne $artifactId -or [string]$artifact.id -cne $artifactId -or
   $artifact.name -cne ('relay-stage-'+$previous.Stage) -or $artifact.expired -ne $false -or
   [string]$artifact.workflow_run.id -cne $runId -or $artifact.workflow_run.head_sha -cne $run.head_sha -or
   $artifact.digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or
   ($artifact.size_in_bytes -isnot [long] -and $artifact.size_in_bytes -isnot [int]) -or
   $artifact.size_in_bytes -le 0 -or $artifact.size_in_bytes -gt 1048576){throw 'Wrong/missing/expired predecessor artifact or digest.'}
$directory=[IO.Path]::GetFullPath($ScratchDirectory)
if(Test-Path -LiteralPath $directory){throw 'Receipt scratch directory must be new.'}
New-Item -ItemType Directory -Path $directory -ErrorAction Stop|Out-Null
$archivePath=Join-Path $directory 'receipt.zip';$stream=$null;$process=$null;$archive=$null;$started=$false
try{
    $stream=[IO.FileStream]::new($archivePath,[IO.FileMode]::CreateNew,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Command gh -CommandType Application -ErrorAction Stop|Select-Object -First 1).Source
    $start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($arg in @('api',"repos/$($target.Repository)/actions/artifacts/$artifactId/zip")){$start.ArgumentList.Add($arg)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    $started=$process.Start();if(!$started){throw 'Artifact transport did not start.'}
    # Never log stderr: native failures may contain short-lived signed redirect URLs.
    $errors=$process.StandardError.BaseStream.CopyToAsync([IO.Stream]::Null)
    $timeout=[Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds(30))
    try{
        $buffer=[byte[]]::new(8192);$total=0
        while(($read=$process.StandardOutput.BaseStream.ReadAsync($buffer,0,$buffer.Length,$timeout.Token).GetAwaiter().GetResult()) -gt 0){
            $total+=$read;if($total -gt 1048576){throw 'Receipt archive exceeds size bound.'}
            $stream.Write($buffer,0,$read)
        }
        if(!$process.WaitForExit(30000)){throw 'Artifact transport timed out.'}
        $errors.GetAwaiter().GetResult()
        if($process.ExitCode -ne 0){throw 'Artifact transport failed.'}
    }finally{$timeout.Dispose()}
    $stream.Flush($true);$stream.Position=0
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)).ToLowerInvariant()
    if(('sha256:'+$digest) -cne $artifact.digest){throw 'Downloaded predecessor archive digest mismatch.'}
    $stream.Position=0
    $archive=[IO.Compression.ZipArchive]::new($stream,[IO.Compression.ZipArchiveMode]::Read,$true)
    if($archive.Entries.Count -ne 1 -or $archive.Entries[0].FullName -cne 'stage-receipt.json' -or
       $archive.Entries[0].Length -le 0 -or $archive.Entries[0].Length -gt 65536){throw 'Unexpected receipt archive entries or size.'}
    $reader=[IO.StreamReader]::new($archive.Entries[0].Open(),[Text.UTF8Encoding]::new($false,$true),$false)
    try{
        $chars=[char[]]::new(65537);$length=0
        while(($read=$reader.Read($chars,$length,$chars.Length-$length)) -gt 0){
            $length+=$read;if($length -gt 65536){throw 'Receipt JSON exceeds size bound.'}
        }
        $receipt=[string]::new($chars,0,$length)|ConvertFrom-Json -NoEnumerate -ErrorAction Stop
    }finally{$reader.Dispose()}
    if($null -eq $receipt -or $receipt.GetType() -ne [System.Management.Automation.PSCustomObject]){throw 'Receipt must be a JSON object.'}
    $receipt
}finally{
    if($process){try{if($started -and !$process.HasExited){$process.Kill($true)}}finally{$process.Dispose()}}
    if($archive){$archive.Dispose()};if($stream){$stream.Dispose()}
    # Only our exact newly created file, followed by nonrecursive empty-directory removal.
    if(Test-Path -LiteralPath $archivePath){[IO.File]::Delete($archivePath)}
    [IO.Directory]::Delete($directory,$false)
}
