param([Parameter(Mandatory)][string]$OutputDirectory,[switch]$BuildOnly)
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot
if($env:GITHUB_REPOSITORY -cne 'SiliconDreamArtists/SovereignTrust.Relay' -or
   $env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$' -or !$env:GITHUB_WORKFLOW_REF){throw 'Release package requires attributable GitHub build-run provenance.'}
& git -C $root diff --quiet HEAD --
if($LASTEXITCODE){throw 'Package must be built from a committed unchanged source snapshot.'}
$untracked=@(& git -C $root ls-files --others --exclude-standard | Where-Object {$_ -notlike 'Documentation/Projects/Working/logs/*'})
if($LASTEXITCODE -or $untracked.Count){throw 'Unexpected untracked input outside isolated test evidence; package provenance is not exact.'}
if(Test-Path -LiteralPath $OutputDirectory){throw 'Package output must be new; never overwrite accepted artifacts.'}
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$output=(Resolve-Path -LiteralPath $OutputDirectory).Path
$publish=Join-Path $output 'publish'
& dotnet publish (Join-Path $root 'Src/CSharp/Azure/SovereignTrust.Relay.Azure/SovereignTrust.Relay.Azure.csproj') --configuration Release --output $publish
if($LASTEXITCODE){throw 'Publish failed'}
foreach($file in @('SovereignTrust.Relay.Azure.dll','SovereignTrust.Relay.Azure.deps.json','SovereignTrust.Relay.Azure.runtimeconfig.json')){
    if(!(Test-Path -LiteralPath (Join-Path $publish $file))){throw "Missing $file"}
}
foreach($file in @('host.json','worker.config.json','local.settings.json','.azurefunctions')){
    if(Test-Path -LiteralPath (Join-Path $publish $file)){throw "Forbidden Functions/secret artifact $file"}
}
& (Join-Path $PSScriptRoot 'Test-RelayPublishedHost.ps1') -PublishDirectory $publish -EvidenceDirectory (Join-Path $output 'host-evidence')
$files=@(Get-ChildItem -LiteralPath $publish -Recurse -File | Sort-Object FullName | ForEach-Object {
    @{path=[IO.Path]::GetRelativePath($publish,$_.FullName).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
})
$zip=Join-Path $output 'relay.zip'
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($publish,$zip)
$runtime=& (Join-Path $PSScriptRoot 'Get-RelayRuntimeIdentity.ps1')
$manifest=@{purpose=$(if($BuildOnly){'build-only'}else{'deployment-release'});eventName=$env:GITHUB_EVENT_NAME;sourceSha=(& git -C $root rev-parse HEAD);sourceTree=(& git -C $root rev-parse 'HEAD^{tree}');sdk=(& dotnet --version);platform=$runtime.platform;os=$runtime.os;repository=$env:GITHUB_REPOSITORY;workflowRunId=$env:GITHUB_RUN_ID;workflowRef=$env:GITHUB_WORKFLOW_REF;sourceRef=$env:GITHUB_REF;packageSha256=(Get-FileHash $zip -Algorithm SHA256).Hash;files=$files}
$manifest|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $output 'release.json') -Encoding utf8NoBOM
Write-Output "Package SHA256 $($manifest.packageSha256); source $($manifest.sourceSha)"
