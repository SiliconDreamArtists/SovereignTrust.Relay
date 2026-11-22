param([Parameter(Mandatory)][string]$EvidenceDirectory)
$ErrorActionPreference='Stop'
if(Test-Path $EvidenceDirectory){throw 'Evidence must be new'}
New-Item -ItemType Directory $EvidenceDirectory|Out-Null
$evidence=(Resolve-Path $EvidenceDirectory).Path;$root=Join-Path $PSScriptRoot '../..'
$contract=Import-PowerShellDataFile (Join-Path $root 'scripts/Relay.Release.psd1');$count=0
function Check([string]$Name,[scriptblock]$Action,[bool]$Reject=$false){
    $failure=$null;try{& $Action|Out-Null}catch{$failure=$_.Exception.Message}
    if($Reject -ne [bool]$failure){throw "FAIL $Name : $failure"};$script:count++;Write-Output "PASS $Name"
}
$envNames=@('GITHUB_REPOSITORY','GITHUB_EVENT_NAME','GITHUB_REF','GITHUB_SHA','GITHUB_RUN_ID','RELAY_CONTROL_COMMIT','RELAY_AZURE_CLIENT_ID','RELAY_AZURE_TENANT_ID','RELAY_AZURE_SUBSCRIPTION_ID','RELAY_PREVIOUS_ACCEPTED_RUN_ID','RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID','RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256','RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256')
$saved=@{};foreach($name in $envNames){$saved[$name]=[Environment]::GetEnvironmentVariable($name)}
$fixture=@{};$apiLog=[Collections.Generic.List[string]]::new()
function az {throw 'Cloud calls forbidden in offline release tests'}
function git {
    if(($args -join ' ') -notmatch 'rev-parse .*manual_deploy_sda-relay.yml'){throw 'Unexpected Git operation'}
    $global:LASTEXITCODE=0;'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
}
function gh {
    $global:LASTEXITCODE=0;$route=[string]$args[1];$apiLog.Add($route)
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
    if($route -like '*/actions/runs/500/artifacts'){
        $artifact=@{name=('relay-stage-'+$fixture.Predecessor);id=900;expired=[bool]$fixture.Expired;workflow_run=@{head_sha=$fixture.Receipt.controlCommit}}
        return (@{artifacts=$(if($fixture.DuplicateStageArtifact){@($artifact,$artifact)}else{@($artifact)})}|ConvertTo-Json -Depth 7)
    }
    if($route -like '*/actions/runs/500'){
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
    $env:GITHUB_SHA='cccccccccccccccccccccccccccccccccccccccc';$env:RELAY_CONTROL_COMMIT=$env:GITHUB_SHA;$env:GITHUB_RUN_ID='500'
    foreach($stage in @('dev','test','prod')){
        Check "fixed target $stage" {
            $sub=@{dev='cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8';test='5c813ecc-3c19-44de-b676-304116fc869d';prod='b7690041-454b-472b-b340-3d8dde115103'}[$stage]
            $t=& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage $stage -ValidateControl
            if($t.AppName -cne "sda-relay-api-$stage" -or $t.Environment -cne "sda-$stage" -or $t.Subscription -cne $sub -or
               $t.AppResourceId -cne "/subscriptions/$sub/resourceGroups/sda-$stage/providers/Microsoft.Web/sites/sda-relay-api-$stage" -or
               $t.PlanResourceId -cne "/subscriptions/$sub/resourceGroups/sda-$stage/providers/Microsoft.Web/serverfarms/ASP-sda-$stage-fusion" -or
               $t.FederationSubject -cne "repo:$($contract.Repository):environment:sda-$stage"){throw 'Mapping mismatch'}
        }
        Check "owner unbound $stage" {& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage $stage -RequireOwner} $true
    }
    # Populate a copy only, to exercise a complete future owner binding without inventing current outputs.
    $ownerDir=Join-Path $evidence 'synthetic-owner-profile';New-Item -ItemType Directory $ownerDir|Out-Null
    Copy-Item (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') $ownerDir
    $profile=Get-Content -Raw (Join-Path $root 'scripts/Relay.Release.psd1')
    $dev=[regex]::Match($profile,'(?ms)^        dev = @\{.*?(?=^        \})').Value
    $synthetic=$dev.Replace("DeploymentClientId = ''","DeploymentClientId = '11111111-1111-1111-1111-111111111111'").Replace("DeploymentPrincipalId = ''","DeploymentPrincipalId = '22222222-2222-2222-2222-222222222222'").Replace("RuntimePrincipalId = ''","RuntimePrincipalId = '33333333-3333-3333-3333-333333333333'").Replace("DefaultHostName = ''","DefaultHostName = 'relay-fixture.azurewebsites.net'").Replace("OwnerPacketSha256 = ''",("OwnerPacketSha256 = '"+('f'*64)+"'"))
    $profile.Replace($dev,$synthetic)|Set-Content (Join-Path $ownerDir 'Relay.Release.psd1') -Encoding utf8NoBOM
    $env:RELAY_AZURE_CLIENT_ID='11111111-1111-1111-1111-111111111111';$env:RELAY_AZURE_TENANT_ID=$contract.TenantId;$env:RELAY_AZURE_SUBSCRIPTION_ID='cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8'
    Check 'synthetic exact owner profile accepted' {& (Join-Path $ownerDir 'Get-RelayReleaseTarget.ps1') -Stage dev -RequireOwner}
    foreach($field in @('RELAY_AZURE_CLIENT_ID','RELAY_AZURE_TENANT_ID','RELAY_AZURE_SUBSCRIPTION_ID')){
        $original=[Environment]::GetEnvironmentVariable($field);[Environment]::SetEnvironmentVariable($field,'99999999-9999-9999-9999-999999999999')
        Check "cross-environment $field rejected" {& (Join-Path $ownerDir 'Get-RelayReleaseTarget.ps1') -Stage dev -RequireOwner} $true
        [Environment]::SetEnvironmentVariable($field,$original)
    }
    Check 'unknown stage' {& (Join-Path $root 'scripts/Get-RelayReleaseTarget.ps1') -Stage arbitrary} $true
    $env:GITHUB_REF='refs/heads/arbitrary';Check 'wrong control ref' {& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')} $true;$env:GITHUB_REF=$contract.ControlRef
    $env:RELAY_CONTROL_COMMIT='dddddddddddddddddddddddddddddddddddddddd';Check 'wrong control commit' {& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')} $true;$env:RELAY_CONTROL_COMMIT=$env:GITHUB_SHA
    $fixture=@{};Check 'new control revision differs from fixed package source' {& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')}
    foreach($case in @('push','pull_request','source','artifact','digest','expired','duplicate','caller-run','caller-sha')){
        $fixture=@{};switch($case){push{$fixture.BuildEvent='push'}pull_request{$fixture.BuildEvent='pull_request'}source{$fixture.BuildSha='0'*40}artifact{$fixture.BuildArtifactId='1'}digest{$fixture.BuildDigest='sha256:'+('0'*64)}expired{$fixture.Expired=$true}duplicate{$fixture.Duplicate=$true}}
        Check "build rejects $case" {if($case -eq 'caller-run'){& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1') -BuildRunId '1'}elseif($case -eq 'caller-sha'){& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1') -ReleaseSha ('0'*40)}else{& (Join-Path $root 'scripts/Test-RelayBuildAcceptance.ps1')}} $true
    }
    foreach($selected in @('dev','test')){
        $fixture=@{Writer=$true;Predecessor=$selected};$path=Join-Path $evidence "writer-$selected.json"
        Check "writer resolves in-progress $selected job" {& (Join-Path $root 'scripts/New-RelayStageReceipt.ps1') -Stage $selected -OutputPath $path}
        $base=Get-Content -Raw $path|ConvertFrom-Json
        Check "writer does not award $selected acceptance" {if($base.acceptance -cne 'not awarded by workflow' -or $base.jobId -cne $(if($selected -eq 'dev'){'42'}else{'43'})){throw 'Wrong writer lifecycle/identity'}}
        $originalReceiptHash=(Get-FileHash $path).Hash
        Check "writer immutable $selected output" {& (Join-Path $root 'scripts/New-RelayStageReceipt.ps1') -Stage $selected -OutputPath $path} $true
        Check "writer preserves existing $selected bytes" {if((Get-FileHash $path).Hash -cne $originalReceiptHash){throw 'Receipt overwritten'}}
        $fixture.Writer=$false
        Check "writer rejects completed $selected job" {& (Join-Path $root 'scripts/New-RelayStageReceipt.ps1') -Stage $selected -OutputPath (Join-Path $evidence "completed-$selected.json")} $true
        foreach($case in @('valid','old-control-ref','missing-owner','self-awarded','wrong-receipt-hash','wrong-artifact','duplicate-artifact','expired','wrong-stage','wrong-target','wrong-package','wrong-job','failed-job','canceled-job','skipped-job','duplicate-job','wrong-stage-success','wrong-run-control','wrong-blob','wrong-structure','wrong-event','failed-run')){
            $receipt=$base|ConvertTo-Json -Depth 6|ConvertFrom-Json;$fixture=@{Predecessor=$selected;Receipt=$receipt}
            $env:RELAY_PREVIOUS_ACCEPTED_RUN_ID='500';$env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID='900';$env:RELAY_PREVIOUS_ACCEPTED_PACKAGE_SHA256=$contract.Package.Sha256
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
            }
            $receiptPath=Join-Path $evidence "$selected-$case.json";$receipt|ConvertTo-Json -Depth 6|Set-Content $receiptPath -Encoding utf8NoBOM
            $env:RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256=(Get-FileHash $receiptPath).Hash;if($case -eq 'wrong-receipt-hash'){$env:RELAY_PREVIOUS_ACCEPTED_RECEIPT_SHA256='0'*64}
            # Control and artifact source are intentionally three different commits.
            $env:GITHUB_SHA='dddddddddddddddddddddddddddddddddddddddd';$env:RELAY_CONTROL_COMMIT=$env:GITHUB_SHA
            $next=if($selected -eq 'dev'){'test'}else{'prod'}
            Check "$next predecessor $case" {& (Join-Path $root 'scripts/Test-RelayPromotion.ps1') -Stage $next -ReceiptPath $receiptPath} ($case -notin @('valid','old-control-ref'))
        }
        $env:GITHUB_SHA='cccccccccccccccccccccccccccccccccccccccc';$env:RELAY_CONTROL_COMMIT=$env:GITHUB_SHA
    }
    Check 'mock API vector exercised and retained' {if($apiLog.Count -lt 10){throw 'Expected actual mocked helper reads'};$apiLog|ConvertTo-Json|Set-Content (Join-Path $evidence 'mocked-gh-reads.json') -Encoding utf8NoBOM}
    Write-Output "Release workflow checks: $count passed; $($apiLog.Count) mocked GitHub reads, zero cloud calls."
}finally{foreach($name in $envNames){[Environment]::SetEnvironmentVariable($name,$saved[$name])}}
