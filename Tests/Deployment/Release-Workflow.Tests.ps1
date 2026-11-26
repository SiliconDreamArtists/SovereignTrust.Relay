param([Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if(Test-Path $EvidenceDirectory){throw 'Evidence must be new'}
New-Item -ItemType Directory $EvidenceDirectory|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path;$root=Join-Path $PSScriptRoot '../..'
$contract=Import-PowerShellDataFile (Join-Path $root 'scripts/Relay.Release.psd1');$count=0
function Check([string]$Name,[scriptblock]$Action,[bool]$Reject=$false){
    $failure=$null;try{& $Action|Out-Null}catch{$failure=$_.Exception.Message}
    if($Reject -ne [bool]$failure){throw "FAIL $Name : $failure"};$script:count++;Write-Output "PASS $Name$(if($failure){' (rejected: '+$failure+')'})"
}
$envNames=@('GITHUB_REPOSITORY','GITHUB_EVENT_NAME','GITHUB_REF','GITHUB_SHA','GITHUB_RUN_ID','RELAY_CONTROL_COMMIT','RELAY_AZURE_CLIENT_ID','RELAY_AZURE_TENANT_ID','RELAY_AZURE_SUBSCRIPTION_ID','RELAY_PREVIOUS_ACCEPTED_RUN_ID','RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID','RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256','RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256','PATH','RELAY_FIXTURE_ARCHIVE','RELAY_FIXTURE_EXIT')
$saved=@{};foreach($name in $envNames){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$fixture=@{};$apiLog=[Collections.Generic.List[string]]::new()
$transport=Join-Path $evidence 'transport';New-Item -ItemType Directory $transport|Out-Null
@'
<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><OutputType>Exe</OutputType><TargetFramework>net10.0</TargetFramework><AssemblyName>gh</AssemblyName><UseAppHost>true</UseAppHost></PropertyGroup></Project>
'@ |Set-Content (Join-Path $transport 'gh.csproj') -Encoding utf8NoBOM
@'
using System; using System.IO;
if (args.Length != 2 || args[0] != "api" || !args[1].EndsWith("/zip")) return 20;
if(Environment.GetEnvironmentVariable("RELAY_FIXTURE_EXIT")=="1") return 21;
using var input=File.OpenRead(Environment.GetEnvironmentVariable("RELAY_FIXTURE_ARCHIVE")!);
using var output=Console.OpenStandardOutput(); input.CopyTo(output); return 0;
'@ |Set-Content (Join-Path $transport 'Program.cs') -Encoding utf8NoBOM
& dotnet build (Join-Path $transport 'gh.csproj') -o (Join-Path $transport 'bin') *> (Join-Path $evidence 'transport-build.log')
if($LASTEXITCODE){throw 'Local transport fixture build failed'}
$env:PATH=(Join-Path $transport 'bin')+[IO.Path]::PathSeparator+$env:PATH
function New-ReceiptArchive($Receipt,[string]$Case){
    $path=Join-Path $evidence ([guid]::NewGuid().ToString()+'.zip')
    $zip=[IO.Compression.ZipFile]::Open($path,[IO.Compression.ZipArchiveMode]::Create)
    try{
        $names=switch($Case){'duplicate-entry'{@('stage-receipt.json','stage-receipt.json')}'traversal'{@('../stage-receipt.json')}'unexpected'{@('other.json')}default{@('stage-receipt.json')}}
        foreach($name in $names){
            $entry=$zip.CreateEntry($name);$stream=$entry.Open()
            try{
                [byte[]]$bytes=if($Case -eq 'invalid-utf8'){[byte[]]@(255,255)}elseif($Case -eq 'oversized-json'){[Text.Encoding]::UTF8.GetBytes('x'*65537)}elseif($Case -eq 'invalid-json'){[Text.Encoding]::UTF8.GetBytes('{')}elseif($Case -eq 'array-root'){[Text.Encoding]::UTF8.GetBytes('['+($Receipt|ConvertTo-Json -Depth 7)+']')}else{[Text.Encoding]::UTF8.GetBytes(($Receipt|ConvertTo-Json -Depth 7))}
                $stream.Write($bytes,0,$bytes.Length)
            }finally{$stream.Dispose()}
        }
    }finally{$zip.Dispose()}
    $fixture.ArchiveDigest='sha256:'+(Get-FileHash $path).Hash.ToLowerInvariant();$fixture.ArchiveSize=(Get-Item $path).Length
    if($Case -eq 'corrupt-archive'){[IO.File]::AppendAllText($path,'tamper')}
    if($Case -eq 'oversized-transport'){[IO.File]::AppendAllText($path,('x'*1048577))}
    if($Case -eq 'truncated-archive'){$bytes=[IO.File]::ReadAllBytes($path);[IO.File]::WriteAllBytes($path,$bytes[0..15])}
    $env:RELAY_FIXTURE_ARCHIVE=$path;$env:RELAY_FIXTURE_EXIT=if($Case -eq 'transport-exit'){'1'}else{''}
}
function az {throw 'Cloud calls forbidden in offline release tests'}
function git {
    if(($args -join ' ') -notmatch 'rev-parse .*manual_deploy_sda-relay.yml'){throw 'Unexpected Git operation'}
    $global:LASTEXITCODE=0;'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
}
function gh {
    $global:LASTEXITCODE=0;$route=[string]$args[1];$apiLog.Add($route)
    if($route -like '*/actions/runs/801' -or ($route -like '*/actions/runs/800' -and !$fixture.Receipt)){
        return (@{repository=@{full_name=($fixture.CurrentRepo ?? $contract.Repository)};path=$contract.WorkflowPath;event=($fixture.CurrentEvent ?? 'workflow_dispatch');status='in_progress';head_sha=($fixture.CurrentSha ?? $env:GITHUB_SHA);head_branch=($fixture.CurrentBranch ?? $contract.ControlRef.Substring(11))}|ConvertTo-Json -Depth 5)
    }
    if($route -like "*/actions/runs/$($contract.Package.BuildRunId)"){
        return (@{repository=@{full_name=$contract.Repository};path=$contract.Package.BuildWorkflowPath;event=($fixture.BuildEvent ?? 'workflow_dispatch');status='completed';conclusion='success';head_sha=($fixture.BuildSha ?? $contract.Package.SourceCommit);head_branch=$contract.Package.SourceRef.Substring(11)}|ConvertTo-Json -Depth 5)
    }
    if($route -like "*/actions/runs/$($contract.Package.BuildRunId)/artifacts"){
        $artifact=@{name=$contract.Package.ArtifactName;id=($fixture.BuildArtifactId ?? $contract.Package.ArtifactId);expired=[bool]$fixture.Expired;workflow_run=@{head_sha=$contract.Package.SourceCommit};digest=($fixture.BuildDigest ?? ('sha256:'+$contract.Package.WrapperSha256))}
        return (@{artifacts=$(if($fixture.Duplicate){@($artifact,$artifact)}else{@($artifact)})}|ConvertTo-Json -Depth 7)
    }
    if($route -like '*/jobs?per_page=100'){
        if(($args -join ' ') -notmatch '--paginate --slurp'){throw 'Jobs pagination missing'}
        $jobs=@();$i=42
        foreach($stage in @('dev','test','prod')){
            $selected=$stage -ceq $fixture.Predecessor
            $jobs+=@{name=$contract.Stages[$stage].JobName;id=$i;status=$(if($fixture.Writer -and $selected){'in_progress'}else{'completed'});conclusion=$(if($selected){$fixture.JobConclusion ?? 'success'}else{'skipped'})};$i++
        }
        if($fixture.WrongStageSuccess){
            $jobs[0].conclusion=$(if($fixture.Predecessor -ceq 'dev'){'skipped'}else{'success'})
            $jobs[1].conclusion=$(if($fixture.Predecessor -ceq 'dev'){'success'}else{'skipped'})
        }
        if($fixture.DuplicateJob){$jobs+=@($jobs[0])}
        # Separate pages ensure the consumer cannot accidentally inspect only the first page.
        return (@(@{jobs=@($jobs[0])},@{jobs=@($jobs|Select-Object -Skip 1)})|ConvertTo-Json -Depth 7)
    }
    if($route -like '*/actions/runs/800/artifacts*' -or $route -like '*/actions/artifacts/*'){
        $artifact=@{name=('relay-stage-'+$fixture.Predecessor);id=900;expired=[bool]$fixture.Expired;size_in_bytes=$fixture.ArchiveSize;digest=($fixture.StageDigest ?? $fixture.ArchiveDigest);workflow_run=@{id=($fixture.ArtifactRun ?? 800);head_sha=($fixture.ArtifactSha ?? $fixture.Receipt.controlCommit)}}
        if($route -like '*/actions/artifacts/*'){return ($artifact|ConvertTo-Json -Depth 7)}
        if($route.Contains('?per_page=100')){
            if(($args -join ' ') -notmatch '--paginate --slurp'){throw 'Artifacts pagination missing'}
            # The selected artifact is always on page2. Duplicate case spans both pages.
            $first=if($fixture.DuplicateStageArtifact){$artifact}else{@{name='unrelated-artifact';id=899}}
            return (@(@{artifacts=@($first)},@{artifacts=@($artifact)})|ConvertTo-Json -Depth 7)
        }
        throw 'Unpaginated predecessor artifact lookup is forbidden; first page has no selected artifact.'
    }
    if($route -like '*/actions/runs/800'){
        return (@{repository=@{full_name=$contract.Repository};path=$contract.WorkflowPath;event=($fixture.RunEvent ?? 'workflow_dispatch');status='completed';conclusion=($fixture.RunConclusion ?? 'success');head_sha=($fixture.RunSha ?? $fixture.Receipt.controlCommit);head_branch=$fixture.Receipt.controlRef.Substring(11)}|ConvertTo-Json -Depth 6)
    }
    if($route -like '*/contents/*?ref=*'){
        $yaml=Get-Content -Raw (Join-Path $root $contract.WorkflowPath)
        if($fixture.WrongStructure){$yaml=$yaml.Replace(('name: Relay deployment '+$fixture.Predecessor),'name: Other job')}
        return (@{sha=($fixture.BlobSha ?? 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee');content=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($yaml))}|ConvertTo-Json)
    }
    throw "Unexpected non-mocked read: $route"
}
try{
    $env:GITHUB_REPOSITORY=$contract.Repository;$env:GITHUB_EVENT_NAME='workflow_dispatch';$env:GITHUB_REF=$contract.ControlRef
    $env:GITHUB_SHA='cccccccccccccccccccccccccccccccccccccccc';$env:GITHUB_RUN_ID='801'
    $env:RELAY_CONTROL_COMMIT='';$env:RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256='';$env:RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256=''
    Check 'no owner hash property remains' {if(@($contract.Stages.Values|Where-Object {$_.ContainsKey('OwnerPacketSha256')}).Count){throw 'Manual owner hash remains'}}
    $env:RELAY_AZURE_CLIENT_ID='';$env:RELAY_AZURE_TENANT_ID='';$env:RELAY_AZURE_SUBSCRIPTION_ID=''
    foreach($stage in @('dev','test','prod')){
        Check "fixed target $stage" {
            $sub=@{dev='cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8';test='5c813ecc-3c19-44de-b676-304116fc869d';prod='b7690041-454b-472b-b340-3d8dde115103'}[$stage]
            $t=& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage $stage -ValidateControl
            if($t.AppName -cne "sda-relay-api-$stage" -or $t.Environment -cne "sda-$stage" -or $t.Subscription -cne $sub -or
               $t.AppResourceId -cne "/subscriptions/$sub/resourceGroups/sda-$stage/providers/Microsoft.Web/sites/sda-relay-api-$stage" -or
               $t.PlanResourceId -cne "/subscriptions/$sub/resourceGroups/sda-$stage/providers/Microsoft.Web/serverfarms/ASP-sda-$stage-fusion" -or
               $t.FederationSubject -cne "repo:$($contract.Repository):environment:sda-$stage"){throw 'Mapping mismatch'}
        }
        Check "absent environment credentials rejected $stage" {& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage $stage -RequireOwner} $true
    }
    Check 'bound Dev owner profile accepted' {
        $credentialNames=@('RELAY_AZURE_CLIENT_ID','RELAY_AZURE_TENANT_ID','RELAY_AZURE_SUBSCRIPTION_ID')
        $priorCredentials=@{};foreach($name in $credentialNames){$priorCredentials[$name]=[Environment]::GetEnvironmentVariable($name)}
        try {
            $env:RELAY_AZURE_CLIENT_ID='8b487a0d-ff5b-4c8b-af47-df5de45c9ebd';$env:RELAY_AZURE_TENANT_ID='8904b745-1738-426c-ad85-3fcecb32d24b';$env:RELAY_AZURE_SUBSCRIPTION_ID='cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8'
            $bound=& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage dev -RequireOwner
            if($bound.Sku -cne 'B2' -or $bound.DeploymentClientId -cne '8b487a0d-ff5b-4c8b-af47-df5de45c9ebd' -or
               $bound.DeploymentPrincipalId -cne '3a48ab88-5916-4e2a-b7cb-94132372e1e7' -or $bound.RuntimePrincipalId -cne '9697fed0-6ae1-462f-b372-152fd3e16184' -or
               $bound.DefaultHostName -cne 'sda-relay-api-dev.azurewebsites.net'){throw 'Bound Dev profile differs from accepted owner outputs'}
        } finally {foreach($name in $credentialNames){if($null -eq $priorCredentials[$name]){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($name,$priorCredentials[$name])}}}
    }
    # Actual Test owner outputs; environment values are confined to this mocked fixture.
    $testOwnerNames=@('RELAY_AZURE_CLIENT_ID','RELAY_AZURE_TENANT_ID','RELAY_AZURE_SUBSCRIPTION_ID','RELAY_PREVIOUS_ACCEPTED_RUN_ID','RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID')
    $testOwnerSaved=@{};foreach($name in $testOwnerNames){$testOwnerSaved[$name]=[Environment]::GetEnvironmentVariable($name)}
    try {
        $env:RELAY_AZURE_CLIENT_ID='52289819-53b8-48b7-a690-4dd88ff297bc'
        $env:RELAY_AZURE_TENANT_ID='8904b745-1738-426c-ad85-3fcecb32d24b'
        $env:RELAY_AZURE_SUBSCRIPTION_ID='5c813ecc-3c19-44de-b676-304116fc869d'
        $env:RELAY_PREVIOUS_ACCEPTED_RUN_ID='45866426041';$env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID='15139584030'
        Check 'bound Test owner profile and accepted Dev pointers accepted' {
            $bound=& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage test -RequireOwner
            if($bound.DeploymentClientId -cne '52289819-53b8-48b7-a690-4dd88ff297bc' -or
               $bound.DeploymentPrincipalId -cne '4c9457de-890d-46b1-9dd1-e56ecbe568bd' -or
               $bound.RuntimePrincipalId -cne '1ed9a5c6-d93c-4c8b-b40e-bf484c2d1999' -or
               $bound.DefaultHostName -cne 'sda-relay-api-test.azurewebsites.net' -or $bound.Sku -cne 'B1' -or
               $bound.AppResourceId -cne '/subscriptions/5c813ecc-3c19-44de-b676-304116fc869d/resourceGroups/sda-test/providers/Microsoft.Web/sites/sda-relay-api-test' -or
               $bound.PlanResourceId -cne '/subscriptions/5c813ecc-3c19-44de-b676-304116fc869d/resourceGroups/sda-test/providers/Microsoft.Web/serverfarms/ASP-sda-test-fusion' -or
               $bound.FederationSubject -cne 'repo:SiliconDreamArtists/SovereignTrust.Relay:environment:sda-test'){throw 'Bound Test profile differs from accepted owner outputs'}
        }
        foreach($name in @('RELAY_AZURE_CLIENT_ID','RELAY_AZURE_TENANT_ID','RELAY_AZURE_SUBSCRIPTION_ID')){
            $actual=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,'99999999-9999-9999-9999-999999999999')
            Check "bound Test rejects wrong $name" {& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage test -RequireOwner} $true
            [Environment]::SetEnvironmentVariable($name,$actual)
        }
        foreach($name in @('RELAY_PREVIOUS_ACCEPTED_RUN_ID','RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID')){
            $actual=[Environment]::GetEnvironmentVariable($name);[Environment]::SetEnvironmentVariable($name,'')
            Check "bound Test rejects missing $name" {& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage test -RequireOwner} $true
            [Environment]::SetEnvironmentVariable($name,$actual)
        }
    } finally {foreach($name in $testOwnerNames){if($null -eq $testOwnerSaved[$name]){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($name,$testOwnerSaved[$name])}}}
    # Populate a copy only, to exercise a complete future owner binding without inventing current outputs.
    $ownerDir=Join-Path $evidence 'synthetic-owner-profile';New-Item -ItemType Directory $ownerDir|Out-Null
    Copy-Item (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') $ownerDir
    $profile=Get-Content -Raw (Join-Path $root 'scripts/Relay.Release.psd1')
    $synthetic=$profile
    foreach($item in @{DeploymentClientId='11111111-1111-1111-1111-111111111111';DeploymentPrincipalId='22222222-2222-2222-2222-222222222222';RuntimePrincipalId='33333333-3333-3333-3333-333333333333';DefaultHostName='relay-fixture.azurewebsites.net'}.GetEnumerator()){
        $synthetic=[regex]::Replace($synthetic,"\b$($item.Key)\s*=\s*'[^']*'","$($item.Key) = '$($item.Value)'")
    }
    $synthetic|Set-Content (Join-Path $ownerDir 'Relay.Release.psd1') -Encoding utf8NoBOM
    $env:RELAY_AZURE_CLIENT_ID='11111111-1111-1111-1111-111111111111';$env:RELAY_AZURE_TENANT_ID=$contract.TenantId;$env:RELAY_AZURE_SUBSCRIPTION_ID='cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8'
    Check 'synthetic exact owner profile accepted' {& (Join-Path $ownerDir 'Get-RelayReleaseTarget.ps1') -Stage dev -RequireOwner}
    foreach($field in @('RELAY_AZURE_CLIENT_ID','RELAY_AZURE_TENANT_ID','RELAY_AZURE_SUBSCRIPTION_ID')){
        $original=[Environment]::GetEnvironmentVariable($field);[Environment]::SetEnvironmentVariable($field,'99999999-9999-9999-9999-999999999999')
        Check "cross-environment $field rejected" {& (Join-Path $ownerDir 'Get-RelayReleaseTarget.ps1') -Stage dev -RequireOwner} $true
        [Environment]::SetEnvironmentVariable($field,$original)
    }
    foreach($stage in @('test','prod')){
        $env:RELAY_AZURE_SUBSCRIPTION_ID=$contract.Stages[$stage].Subscription
        $env:RELAY_PREVIOUS_ACCEPTED_RUN_ID='800';$env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID='900'
        Check "synthetic exact owner $stage without manual hashes" {& (Join-Path $ownerDir 'Get-RelayReleaseTarget.ps1') -Stage $stage -RequireOwner}
        $env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID=''
        Check "synthetic owner $stage rejects absent acceptance ID" {& (Join-Path $ownerDir 'Get-RelayReleaseTarget.ps1') -Stage $stage -RequireOwner} $true
    }
    Check 'unknown stage' {& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage arbitrary} $true
    Check 'fixed main control ref' {if($contract.ControlRef -cne 'refs/heads/main'){throw 'Control ref must be main'}}
    $env:GITHUB_REF='refs/heads/main';Check 'main control ref accepted' {& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')}
    foreach($ref in @('refs/heads/agents/relay-azure-to-aspnet-core-migration','refs/heads/arbitrary')){
        $env:GITHUB_REF=$ref;Check "wrong control ref $ref" {& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')} $true
    }
    $env:GITHUB_REF=$contract.ControlRef
    $env:RELAY_CONTROL_COMMIT='ignored legacy value';Check 'legacy manual control hash is ignored' {& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')};$env:RELAY_CONTROL_COMMIT=''
    foreach($case in @('CurrentRepo','CurrentEvent','CurrentSha','CurrentBranch')){
        $fixture=@{};$fixture[$case]='wrong';Check "authenticated current run rejects $case" {& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')} $true
    }
    $fixture=@{};Check 'new control revision differs from fixed package source' {& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')}
    foreach($case in @('push','pull_request','source','artifact','digest','expired','duplicate','caller-run','caller-sha')){
        $fixture=@{};switch($case){push{$fixture.BuildEvent='push'}pull_request{$fixture.BuildEvent='pull_request'}source{$fixture.BuildSha='0'*40}artifact{$fixture.BuildArtifactId='1'}digest{$fixture.BuildDigest='sha256:'+('0'*64)}expired{$fixture.Expired=$true}duplicate{$fixture.Duplicate=$true}}
        Check "build rejects $case" {if($case -eq 'caller-run'){& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1') -BuildRunId '1'}elseif($case -eq 'caller-sha'){& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1') -ReleaseSha ('0'*40)}else{& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')}} $true
    }
    foreach($selected in @('dev','test')){
        $env:GITHUB_RUN_ID='800'
        $fixture=@{Writer=$true;Predecessor=$selected};$path=Join-Path $evidence "writer-$selected.json"
        Check "writer resolves in-progress $selected job" {& (Join-Path $root 'scripts/New-RelayStageReceipt.ps1') -Stage $selected -OutputPath $path}
        $base=Get-Content -Raw $path|ConvertFrom-Json
        Check "writer does not award $selected acceptance" {if($base.acceptance -cne 'not awarded by workflow' -or $base.jobId -cne $(if($selected -eq 'dev'){'42'}else{'43'})){throw 'Wrong writer lifecycle/identity'}}
        $originalReceiptHash=(Get-FileHash $path).Hash
        Check "writer immutable $selected output" {& (Join-Path $root 'scripts/New-RelayStageReceipt.ps1') -Stage $selected -OutputPath $path} $true
        Check "writer preserves existing $selected bytes" {if((Get-FileHash $path).Hash -cne $originalReceiptHash){throw 'Receipt overwritten'}}
        $fixture.Writer=$false
        Check "writer rejects completed $selected job" {& (Join-Path $root 'scripts/New-RelayStageReceipt.ps1') -Stage $selected -OutputPath (Join-Path $evidence "completed-$selected.json")} $true
        $env:GITHUB_RUN_ID='801'
        foreach($case in @('valid','legacy-hashes-ignored','old-control-ref','missing-owner','self-awarded','corrupt-archive','truncated-archive','oversized-transport','missing-digest','malformed-digest','artifact-source','artifact-run','duplicate-entry','traversal','unexpected','oversized-json','invalid-utf8','invalid-json','array-root','package-array','nonscalar','transport-exit','scratch-collision','wrong-artifact','duplicate-artifact','expired','wrong-stage','wrong-target','wrong-package','wrong-job','failed-job','canceled-job','skipped-job','duplicate-job','wrong-stage-success','wrong-run-control','wrong-blob','wrong-structure','wrong-event','failed-run')){
            $receipt=$base|ConvertTo-Json -Depth 6|ConvertFrom-Json;$fixture=@{Predecessor=$selected;Receipt=$receipt}
            $env:RELAY_PREVIOUS_ACCEPTED_RUN_ID='800';$env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID='900'
            $env:RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256='';$env:RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256=''
            switch($case){
                old-control-ref{$receipt.controlRef='refs/heads/previous-reviewed-control'}
                missing-owner{$env:RELAY_PREVIOUS_ACCEPTED_RUN_ID=''}
                self-awarded{$receipt.acceptance='accepted';$env:RELAY_PREVIOUS_ACCEPTED_RUN_ID=''}
                wrong-artifact{$env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID='901'}
                duplicate-artifact{$fixture.DuplicateStageArtifact=$true}
                expired{$fixture.Expired=$true}
                wrong-stage{$receipt.stage='prod'}
                wrong-target{$receipt.targetAppResourceId=$receipt.targetAppResourceId.Replace('sda-relay-api-','sda-fusion-')}
                wrong-package{$receipt.package.Sha256='0'*64}
                wrong-job{$receipt.jobId='999'}
                failed-job{$fixture.JobConclusion='failure'}
                canceled-job{$fixture.JobConclusion='cancelled'}
                skipped-job{$fixture.JobConclusion='skipped'}
                duplicate-job{$fixture.DuplicateJob=$true}
                wrong-stage-success{$fixture.WrongStageSuccess=$true}
                wrong-run-control{$fixture.RunSha='0'*40}
                wrong-blob{$fixture.BlobSha='0'*40}
                wrong-structure{$fixture.WrongStructure=$true}
                wrong-event{$fixture.RunEvent='push'}
                failed-run{$fixture.RunConclusion='failure'}
                legacy-hashes-ignored{$env:RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256='bogus';$env:RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256='bogus'}
                missing-digest{$fixture.StageDigest=''}
                malformed-digest{$fixture.StageDigest='sha256:wrong'}
                artifact-source{$fixture.ArtifactSha='0'*40}
                artifact-run{$fixture.ArtifactRun=999}
                nonscalar{$receipt.stage=@('dev','test')}
                package-array{$receipt.package.Sha256=@($contract.Package.Sha256)}
            }
            $receiptPath=Join-Path $evidence "$selected-$case.json";$receipt|ConvertTo-Json -Depth 6|Set-Content $receiptPath -Encoding utf8NoBOM
            New-ReceiptArchive $receipt $case
            $scratch=Join-Path $evidence ($selected+'-'+$case+'-scratch')
            if($case -eq 'scratch-collision'){New-Item -ItemType Directory $scratch|Out-Null;'preserve'|Set-Content (Join-Path $scratch 'unrelated.txt')}
            # Control and artifact source are intentionally three different commits.
            $env:GITHUB_SHA='dddddddddddddddddddddddddddddddddddddddd'
            $next=if($selected -eq 'dev'){'test'}else{'prod'}
            Check "$next predecessor $case" {& (Join-Path $root 'scripts/Test-RelayPromotion.ps1') -Stage $next -ScratchDirectory $scratch} ($case -notin @('valid','legacy-hashes-ignored','old-control-ref'))
            Check "$next scratch boundary $case" {if($case -eq 'scratch-collision'){if((Get-Content (Join-Path $scratch 'unrelated.txt')) -cne 'preserve'){throw 'Existing scratch changed'}}elseif(Test-Path $scratch){throw 'Owned scratch not cleaned'}}
        }
        $env:GITHUB_SHA='cccccccccccccccccccccccccccccccccccccccc'
    }
    Check 'no unpaginated predecessor artifact lookup attempted' {if(@($apiLog|Where-Object {$_ -match '/actions/runs/800/artifacts$'}).Count){throw 'First-page-only query attempted'}}
    Check 'mock API vector exercised and retained' {if($apiLog.Count -lt 10){throw 'Expected actual mocked helper reads'};$apiLog|ConvertTo-Json|Set-Content (Join-Path $evidence 'mocked-gh-reads.json') -Encoding utf8NoBOM}
    Write-Output "Release workflow checks: $count passed; $($apiLog.Count) mocked GitHub reads, zero cloud calls."
}finally{foreach($name in $envNames){if($null -eq $saved[$name]){Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue}else{[Environment]::SetEnvironmentVariable($name,$saved[$name])}}}
