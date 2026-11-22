param([Parameter(Mandatory)][string]$PackageDirectory,[Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$ReleaseSha,
      [string]$AcceptedPackageSha256,[switch]$BuildOnly,[string]$ExpectedBuildRunId)
$ErrorActionPreference='Stop'
$manifest=Get-Content -Raw -LiteralPath (Join-Path $PackageDirectory 'release.json')|ConvertFrom-Json
if($manifest.sourceSha -cne $ReleaseSha -or $manifest.packageSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
    (Get-FileHash -LiteralPath (Join-Path $PackageDirectory 'relay.zip') -Algorithm SHA256).Hash -ine $manifest.packageSha256){throw 'Package/source identity mismatch.'}
if($PSBoundParameters.ContainsKey('ExpectedBuildRunId') -and
   ($ExpectedBuildRunId -notmatch '^[1-9][0-9]*$' -or $manifest.workflowRunId -cne $ExpectedBuildRunId)){throw 'Package build-run identity mismatch.'}
$publicFields=@();foreach($field in @('sourceSha','sourceTree','sdk','repository','workflowRunId','workflowRef','sourceRef','platform','purpose','eventName')){
    $value=$manifest.$field
    $publicFields+=@{field=$field;value=$value;type=$(if($null -eq $value){'null'}else{$value.GetType().FullName})}
}
$invalid=@()
if($manifest.sourceTree -isnot [string] -or $manifest.sourceTree -notmatch '^[a-f0-9]{40}$'){$invalid+='sourceTree'}
if($manifest.sdk -isnot [string] -or $manifest.sdk -notmatch '^10\.'){$invalid+='sdk'}
if($manifest.repository -isnot [string] -or $manifest.repository -cne 'SiliconDreamArtists/SovereignTrust.Relay'){$invalid+='repository'}
if($manifest.workflowRunId -isnot [string] -or $manifest.workflowRunId -notmatch '^[1-9][0-9]*$'){$invalid+='workflowRunId'}
if($manifest.workflowRef -isnot [string] -or [string]::IsNullOrWhiteSpace($manifest.workflowRef)){$invalid+='workflowRef'}
if($invalid.Count){
    Write-Output ('Validator public provenance fields: '+($publicFields|ConvertTo-Json -Compress -Depth 4))
    throw "Incomplete source/build-run provenance: $($invalid -join ', ')."
}
if($BuildOnly){
    $validEventRef=($manifest.eventName -in @('push','workflow_dispatch') -and $manifest.sourceRef -match '^refs/heads/') -or
        ($manifest.eventName -ceq 'pull_request' -and $manifest.sourceRef -match '^refs/pull/[1-9][0-9]*/merge$')
    if($manifest.purpose -cne 'build-only' -or !$validEventRef){throw 'Invalid nondeployment CI event/ref.'}
}elseif($manifest.purpose -cne 'deployment-release' -or $manifest.eventName -cne 'workflow_dispatch' -or
    $manifest.sourceRef -notmatch '^refs/heads/'){
    throw 'Deployment requires a manual branch release; build-only/PR artifacts cannot deploy.'
}
$expectedTree=@(& git -C (Split-Path $PSScriptRoot) rev-parse "$ReleaseSha^{tree}");$treeExit=$LASTEXITCODE
if($treeExit -ne 0 -or $expectedTree.Count -ne 1 -or $expectedTree[0] -notmatch '^[a-f0-9]{40}$' -or $manifest.sourceTree -cne $expectedTree[0]){
    Write-Output ('Validator public Git provenance: '+(@{expectedTree=$expectedTree;exit=$treeExit;manifestTree=$manifest.sourceTree}|ConvertTo-Json -Compress))
    throw 'Source tree does not match selected release commit.'
}
Write-Output 'Validated scalar source/build-run metadata and native Git tree; platform/package checks still required.'
if($manifest.platform -cne 'Linux'){throw 'Deployment requires structured Linux runtime platform provenance.'}
foreach($required in @('SovereignTrust.Relay.Azure.dll','SovereignTrust.Relay.Azure.deps.json','SovereignTrust.Relay.Azure.runtimeconfig.json','runtimes/linux-x64/native/libsodium.so')){
    if(@($manifest.files|Where-Object path -CEQ $required).Count -ne 1){throw "Missing required Linux package file: $required"}
}
if($PSBoundParameters.ContainsKey('AcceptedPackageSha256') -and
   ($AcceptedPackageSha256 -notmatch '^[A-Fa-f0-9]{64}$' -or $manifest.packageSha256 -ine $AcceptedPackageSha256)){throw 'Package does not match owner-accepted previous environment receipt.'}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::OpenRead((Join-Path $PackageDirectory 'relay.zip'))
try {
    $entries=@($zip.Entries|Where-Object {$_.Name})
    if($entries.Count -ne $manifest.files.Count){throw 'Package manifest count mismatch'}
    foreach($entry in $entries){
        if($entry.FullName -match '(^/|\\|(^|/)\.\.(/|$)|(^|/)(local\.settings\.json|host\.json|worker\.config\.json|\.azurefunctions)(/|$))'){throw 'Unsafe/forbidden ZIP entry'}
        $file=@($manifest.files|Where-Object path -CEQ $entry.FullName)
        if($file.Count -ne 1){throw 'Missing/duplicate manifest entry'}
        $stream=$entry.Open()
        try{$hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}
        if($hash -ine $file[0].sha256){throw 'ZIP content hash mismatch'}
    }
}finally{$zip.Dispose()}
Write-Output "Verified package integrity/provenance fields $($manifest.packageSha256); matching Linux runtime receipt still required."
