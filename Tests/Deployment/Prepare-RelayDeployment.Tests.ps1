# Offline target-validation tests; every Azure operation is mocked and must be read-only.
$ErrorActionPreference='Stop'
$target=Join-Path $PSScriptRoot '../../scripts/Prepare-RelayDeployment.ps1'
$appId='/subscriptions/cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8/resourceGroups/sda-dev/providers/Microsoft.Web/sites/sda-relay-api-dev'
$planId='/subscriptions/cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8/resourceGroups/sda-dev/providers/Microsoft.Web/serverfarms/ASP-sda-dev-fusion'
$fixture=@{};$count=0;$reads=[Collections.Generic.List[string]]::new()
function az {
    $global:LASTEXITCODE=0
    $cmd=$args -join ' '
    $reads.Add($cmd)
    if($cmd -notmatch '--subscription cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8'){throw 'Explicit subscription missing'}
    if($cmd -match '^resource show '){
        @{id=$appId;kind=$fixture.Kind;properties=@{state=$fixture.State;serverFarmId=$fixture.Plan;httpsOnly=$fixture.Https}}|ConvertTo-Json -Depth 5
    } elseif($cmd -match '^webapp config show '){@{linuxFxVersion=$fixture.Runtime;alwaysOn=$fixture.AlwaysOn}|ConvertTo-Json
    } elseif($cmd -match '^webapp config appsettings list ' -and $cmd -match '\[\]\.name'){
        $fixture.Names|ConvertTo-Json
    } elseif($cmd -match '^webapp config appsettings list ' -and $cmd -match 'ENABLE_ED25519_SIGNING'){
        $fixture.Flag|ConvertTo-Json
    } else {throw "Forbidden operation: $cmd"}
}
$cases=@('Valid','WrongApp','WrongPlanArgument','WrongEnvironment','FunctionKind','UnknownState','Stopped','WrongPlanActual','HttpsOff','WrongRuntime','AlwaysOnOff','MissingSetting','SigningEnabled','MissingFlag')
foreach($purpose in @('Default','RuntimeReady','PackagePlacement')){
foreach($case in $cases){
    $reads.Clear()
    $fixture=@{Kind='app,linux';State='Running';Plan=$planId;Https=$true;Runtime='DOTNETCORE|10.0';AlwaysOn=$true;Names=@('DISCORD_PUBLIC_KEY','StorageQueueAccount','DISCORD_QUEUE_NAME','DISCORD_DEDUP_CONTAINER','ENABLE_ED25519_SIGNING');Flag='false'}
    $argsToUse=@{Environment='Dev';AppResourceId=$appId;PlanResourceId=$planId}
    if($purpose -ne 'Default'){$argsToUse.Purpose=$purpose}
    switch($case){
        WrongApp {$argsToUse.AppResourceId=$appId.Replace('sda-relay-api-dev','sda-fusion-dev')}
        WrongPlanArgument {$argsToUse.PlanResourceId=$planId+'-wrong'}
        WrongEnvironment {$argsToUse.Environment='Prod'}
        FunctionKind {$fixture.Kind='functionapp,linux'}
        UnknownState {$fixture.State=$null}
        Stopped {$fixture.State='Stopped'}
        WrongPlanActual {$fixture.Plan=$planId+'-wrong'}
        HttpsOff {$fixture.Https=$false}
        WrongRuntime {$fixture.Runtime='DOTNET-ISOLATED|10.0'}
        AlwaysOnOff {$fixture.AlwaysOn=$false}
        MissingSetting {$fixture.Names=@('ENABLE_ED25519_SIGNING')}
        SigningEnabled {$fixture.Flag='true'}
        MissingFlag {$fixture.Flag=$null}
    }
    $failure=$null
    $observed=@();try { $observed=@(& $target @argsToUse) } catch {$failure=$_.Exception.Message}
    $expectedSuccess=$case -eq 'Valid' -or ($purpose -eq 'PackagePlacement' -and $case -eq 'MissingSetting')
    if($expectedSuccess -eq [bool]$failure){throw "FAIL $purpose $case : $failure"}
    if($expectedSuccess){
        $label=if($purpose -eq 'PackagePlacement'){'Validated PackagePlacement infrastructure'}else{'Validated RuntimeReady setting names and infrastructure'}
        if(($observed -join '') -notlike ($label+'*') -or ($observed -join '') -notmatch 'unproved|no runtime readiness'){throw 'Missing scoped output label'}
    }
    if($purpose -eq 'PackagePlacement' -and @($reads|Where-Object {$_ -match '\[\]\.name'}).Count){throw 'Placement must not require runtime setting names'}
    $count++;Write-Output "PASS $purpose $case$(if($failure){' (rejected: '+$failure+')'})"
}
}
$failure=$null;try{& $target -Environment Dev -AppResourceId $appId -PlanResourceId $planId -Purpose Unknown|Out-Null}catch{$failure=$_.Exception.Message}
if(!$failure){throw 'Unknown purpose accepted'};$count++;Write-Output 'PASS Unknown purpose rejected'
Write-Output "Preflight checks: $count passed; mocked Azure reads only, zero HTTP probes/writes."
