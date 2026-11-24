param([Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if(Test-Path $EvidenceDirectory){throw 'Fixture directory must be new'}
New-Item -ItemType Directory $EvidenceDirectory|Out-Null
$root=Join-Path $PSScriptRoot '../..'
$policy=Get-Content -Raw (Join-Path $root 'global.json')|ConvertFrom-Json
$selectedSdk=@(& dotnet --version);$sdkExit=$LASTEXITCODE
if($policy.sdk.version -cne '10.0.100' -or $policy.sdk.rollForward -cne 'latestFeature' -or $policy.sdk.allowPrerelease -ne $false -or
   $sdkExit -ne 0 -or $selectedSdk.Count -ne 1 -or $selectedSdk[0] -notmatch '^10\.'){
    throw "SDK 10 policy/actual selection failed: exit=$sdkExit; output=$($selectedSdk -join ', ')"
}
Write-Output "PASS actual SDK selection $($selectedSdk[0]) under repository policy"
$sha=git -C $root rev-parse HEAD
$tree=git -C $root rev-parse 'HEAD^{tree}'
$package=Join-Path (Resolve-Path $EvidenceDirectory) 'synthetic-package'
New-Item -ItemType Directory $package|Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip=[IO.Compression.ZipFile]::Open((Join-Path $package 'relay.zip'),[IO.Compression.ZipArchiveMode]::Create)
$paths=@('SovereignTrust.Relay.Azure.dll','SovereignTrust.Relay.Azure.deps.json','SovereignTrust.Relay.Azure.runtimeconfig.json','runtimes/linux-x64/native/libsodium.so')
try {foreach($path in $paths){$entry=$zip.CreateEntry($path);$writer=[IO.StreamWriter]::new($entry.Open());$writer.Write('synthetic integrity fixture, not a runnable Linux package');$writer.Dispose()}}finally{$zip.Dispose()}
$stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('synthetic integrity fixture, not a runnable Linux package'))
try{$fileHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream))}finally{$stream.Dispose()}
$runtime=& (Join-Path $root 'scripts/Get-RelayRuntimeIdentity.ps1')
$expectedPlatform=if($IsLinux){'Linux'}elseif($IsWindows){'Windows'}else{'Other'}
if($runtime.platform -cne $expectedPlatform -or $runtime.os -cne [Runtime.InteropServices.RuntimeInformation]::OSDescription){throw 'Runtime platform oracle disagrees with actual host identity'}
Write-Output "PASS actual runtime platform oracle $($runtime.platform) (description informational)"
$manifest=@{purpose='deployment-release';eventName='workflow_dispatch';sourceSha=$sha;sourceTree=$tree;sdk='10.0.404';platform='Linux';os='Ubuntu 24.04.3 LTS (synthetic validator fixture)';repository='SiliconDreamArtists/SovereignTrust.Relay';workflowRunId='123';workflowRef='repo/workflow@refs/heads/reviewed';sourceRef='refs/heads/reviewed';packageSha256=(Get-FileHash (Join-Path $package 'relay.zip')).Hash;files=@($paths|ForEach-Object {@{path=$_;sha256=$fileHash}})}
function Write-Manifest { $manifest|ConvertTo-Json -Depth 6|Set-Content (Join-Path $package 'release.json') -Encoding utf8NoBOM }
Write-Manifest
& (Join-Path $root 'scripts/Test-RelayPackage.ps1') -PackageDirectory $package -ReleaseSha $sha -ExpectedBuildRunId '123'
Write-Output 'PASS synthetic Ubuntu description without Linux accepted by structured platform (not runtime acceptance)'
foreach($case in @('WrongSource','WrongPackageHash','WrongPlatform','MissingPlatform','WrongSdk','ArraySdk','MissingProvenance','WrongFileHash','UnacceptedPackage','WrongBuildRun')){
    $copy=$manifest|ConvertTo-Json -Depth 6|ConvertFrom-Json -AsHashtable
    switch($case){
        WrongSource {$manifest.sourceSha='2222222222222222222222222222222222222222'}
        WrongPackageHash {$manifest.packageSha256='0'*64}
        WrongPlatform {$manifest.platform='Windows';$manifest.os='Linux (misleading description must not authorize Windows)'}
        MissingPlatform {$manifest.Remove('platform')}
        WrongSdk {$manifest.sdk='11.0.100'}
        ArraySdk {$manifest.sdk=@('10.0.404','unexpected native output')}
        MissingProvenance {$manifest.workflowRunId=''}
        WrongFileHash {$manifest.files[0].sha256='0'*64}
    }
    Write-Manifest;$failure=$null
    try {
        if($case -eq 'UnacceptedPackage'){& (Join-Path $root 'scripts/Test-RelayPackage.ps1') -PackageDirectory $package -ReleaseSha $sha -AcceptedPackageSha256 ('0'*64)|Out-Null}
        elseif($case -eq 'WrongBuildRun'){& (Join-Path $root 'scripts/Test-RelayPackage.ps1') -PackageDirectory $package -ReleaseSha $sha -ExpectedBuildRunId '999'|Out-Null}
        else{& (Join-Path $root 'scripts/Test-RelayPackage.ps1') -PackageDirectory $package -ReleaseSha $sha|Out-Null}
    }catch{$failure=$_.Exception.Message}
    if(!$failure){throw "FAIL $case accepted"}
    if($case -in @('WrongSdk','ArraySdk') -and $failure -notmatch 'provenance: sdk'){throw "FAIL $case wrong discriminating error: $failure"}
    Write-Output "PASS $case rejected";$manifest=$copy
}
Write-Manifest
# Execute the verifier's actual event/mode branches; synthetic bytes never establish runtime success.
foreach($case in @('BuildPush','BuildPr','BuildPrWrongRef','PrAsRelease','BuildPushAsRelease','ReleaseAsBuildOnly')){
    $copy=$manifest|ConvertTo-Json -Depth 6|ConvertFrom-Json -AsHashtable
    $manifest.purpose='build-only';$manifest.eventName='push';$manifest.sourceRef='refs/heads/reviewed';$mode=$true
    switch($case){
        BuildPr {$manifest.eventName='pull_request';$manifest.sourceRef='refs/pull/42/merge'}
        BuildPrWrongRef {$manifest.eventName='pull_request'}
        PrAsRelease {$manifest.eventName='pull_request';$manifest.sourceRef='refs/pull/42/merge';$mode=$false}
        BuildPushAsRelease {$mode=$false}
        ReleaseAsBuildOnly {$manifest.purpose='deployment-release';$manifest.eventName='workflow_dispatch'}
    }
    Write-Manifest;$failure=$null
    try {& (Join-Path $root 'scripts/Test-RelayPackage.ps1') -PackageDirectory $package -ReleaseSha $sha -BuildOnly:$mode|Out-Null}catch{$failure=$_.Exception.Message}
    $expectedSuccess=$case -in @('BuildPush','BuildPr')
    if($expectedSuccess -eq [bool]$failure){throw "FAIL event/mode $case : $failure"}
    Write-Output "PASS event/mode $case";$manifest=$copy
}
Write-Manifest
# Consolidated deployment-control/stage fixtures live in Release-Workflow.Tests.ps1.
