param([Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if(Test-Path $EvidenceDirectory){throw 'Fixture directory must be new'}
New-Item -ItemType Directory $EvidenceDirectory|Out-Null
$root=Join-Path $PSScriptRoot '../..'
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
foreach($case in @('WrongSource','WrongPackageHash','WrongPlatform','MissingPlatform','MissingProvenance','WrongFileHash','UnacceptedPackage','WrongBuildRun')){
    $copy=$manifest|ConvertTo-Json -Depth 6|ConvertFrom-Json -AsHashtable
    switch($case){
        WrongSource {$manifest.sourceSha='2222222222222222222222222222222222222222'}
        WrongPackageHash {$manifest.packageSha256='0'*64}
        WrongPlatform {$manifest.platform='Windows';$manifest.os='Linux (misleading description must not authorize Windows)'}
        MissingPlatform {$manifest.Remove('platform')}
        MissingProvenance {$manifest.workflowRunId=''}
        WrongFileHash {$manifest.files[0].sha256='0'*64}
    }
    Write-Manifest;$failure=$null
    try {
        if($case -eq 'UnacceptedPackage'){& (Join-Path $root 'scripts/Test-RelayPackage.ps1') -PackageDirectory $package -ReleaseSha $sha -AcceptedPackageSha256 ('0'*64)|Out-Null}
        elseif($case -eq 'WrongBuildRun'){& (Join-Path $root 'scripts/Test-RelayPackage.ps1') -PackageDirectory $package -ReleaseSha $sha -ExpectedBuildRunId '999'|Out-Null}
        else{& (Join-Path $root 'scripts/Test-RelayPackage.ps1') -PackageDirectory $package -ReleaseSha $sha|Out-Null}
    }catch{$failure=$_.Exception.Message}
    if(!$failure){throw "FAIL $case accepted"};Write-Output "PASS $case rejected";$manifest=$copy
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
# Mock all GitHub reads; no network/dispatch or Azure effects.
$saved=@{};foreach($name in @('GITHUB_REPOSITORY','RELAY_RELEASE_REF','GITHUB_REF','GITHUB_SHA','RELAY_PREVIOUS_ACCEPTED_RUN_ID','RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256','RELAY_ACCEPTED_BUILD_RUN_ID','RELAY_ACCEPTED_BUILD_ARTIFACT_ID','RELAY_ACCEPTED_BUILD_PACKAGE_SHA256')){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
try{
    $env:GITHUB_REPOSITORY='SiliconDreamArtists/SovereignTrust.Relay';$env:RELAY_RELEASE_REF='refs/heads/reviewed';$env:GITHUB_REF=$env:RELAY_RELEASE_REF;$env:GITHUB_SHA=$sha;$env:RELAY_PREVIOUS_ACCEPTED_RUN_ID='123';$env:RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256=$manifest.packageSha256
    $fixture=@{}
    function gh {
        $global:LASTEXITCODE=0
        if(($args -join ' ') -like '*/artifacts'){@{artifacts=@(@{name=($fixture.ArtifactName ?? 'relay-release');id=456;expired=$fixture.Expired;workflow_run=@{head_sha=$sha}})}|ConvertTo-Json -Depth 6}
        else{@{repository=@{full_name='SiliconDreamArtists/SovereignTrust.Relay'};path=$fixture.Path;event=$fixture.Event;conclusion=$fixture.Conclusion;head_sha=$fixture.Sha;head_branch=($fixture.Branch ?? 'reviewed')}|ConvertTo-Json}
    }
    foreach($case in @('Valid','PushOrigin','PrOrigin','WrongWorkflow','FailedRun','WrongSource','WrongRef','Expired','WrongArtifactId','MissingAcceptance')){
        $fixture=@{Path='.github/workflows/main_publish_sda-relay-dev.yml';Event='workflow_dispatch';Conclusion='success';Sha=$sha;Expired=$false;ArtifactName='relay-manual-package';Branch='reviewed'}
        $env:RELAY_ACCEPTED_BUILD_RUN_ID='123';$env:RELAY_ACCEPTED_BUILD_ARTIFACT_ID='456';$env:RELAY_ACCEPTED_BUILD_PACKAGE_SHA256=$manifest.packageSha256
        switch($case){PushOrigin{$fixture.Event='push'}PrOrigin{$fixture.Event='pull_request'}WrongWorkflow{$fixture.Path='arbitrary.yml'}FailedRun{$fixture.Conclusion='failure'}WrongSource{$fixture.Sha='0'*40}WrongRef{$fixture.Branch='unreviewed'}Expired{$fixture.Expired=$true}WrongArtifactId{$env:RELAY_ACCEPTED_BUILD_ARTIFACT_ID='999'}MissingAcceptance{$env:RELAY_ACCEPTED_BUILD_RUN_ID=''}}
        $failure=$null;try{& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1') -BuildRunId '123' -ReleaseSha $sha|Out-Null}catch{$failure=$_.Exception.Message}
        if(($case -eq 'Valid') -eq [bool]$failure){throw "FAIL accepted build $case : $failure"};Write-Output "PASS accepted build $case"
    }
    foreach($case in @('Valid','FailedRun','WrongWorkflow','BuildOnlyCi','PullRequest','WrongSha','Expired','NoIndependentAcceptance')){
        $fixture=@{Path='.github/workflows/manual_deploy_sda-relay-dev.yml';Event='workflow_dispatch';Conclusion='success';Sha=$sha;Expired=$false};$env:RELAY_PREVIOUS_ACCEPTED_RUN_ID='123'
        switch($case){FailedRun{$fixture.Conclusion='failure'}WrongWorkflow{$fixture.Path='arbitrary.yml'}BuildOnlyCi{$fixture.Path='.github/workflows/main_publish_sda-relay-dev.yml';$fixture.Event='push'}PullRequest{$fixture.Event='pull_request'}WrongSha{$fixture.Sha='0'*40}Expired{$fixture.Expired=$true}NoIndependentAcceptance{$env:RELAY_PREVIOUS_ACCEPTED_RUN_ID=''}}
        $failure=$null;try{& (Join-Path $root 'scripts/Test-RelayPromotion.ps1') -Environment Test -PreviousRunId '123' -ReleaseSha $sha|Out-Null}catch{$failure=$_.Exception.Message}
        if(($case -eq 'Valid') -eq [bool]$failure){throw "FAIL promotion $case : $failure"};Write-Output "PASS promotion $case"
    }
}finally{foreach($name in $saved.Keys){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
