# Offline target-validation tests; every Azure operation is mocked and must be read-only.
$ErrorActionPreference='Stop'
$target=Join-Path $PSScriptRoot '../../scripts/Prepare-RelayDeployment.ps1'
$appId='/subscriptions/cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8/resourceGroups/sda-dev/providers/Microsoft.Web/sites/sda-relay-api-dev'
$planId='/subscriptions/cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8/resourceGroups/sda-dev/providers/Microsoft.Web/serverfarms/ASP-sda-dev-fusion'
$fixture=@{}
function az {
    $global:LASTEXITCODE=0
    $cmd=$args -join ' '
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
$cases=@('Valid','WrongApp','WrongPlanArgument','WrongEnvironment','FunctionKind','UnknownState','Stopped','WrongPlanActual','HttpsOff','WrongRuntime','AlwaysOnOff','MissingSetting','SigningEnabled')
foreach($case in $cases){
    $fixture=@{Kind='app,linux';State='Running';Plan=$planId;Https=$true;Runtime='DOTNETCORE|10.0';AlwaysOn=$true;Names=@('DISCORD_PUBLIC_KEY','StorageQueueAccount','DISCORD_QUEUE_NAME','DISCORD_DEDUP_CONTAINER','ENABLE_ED25519_SIGNING');Flag='false'}
    $argsToUse=@{Environment='Dev';AppResourceId=$appId;PlanResourceId=$planId}
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
        MissingSetting {$fixture.Names=@('DISCORD_PUBLIC_KEY')}
        SigningEnabled {$fixture.Flag='true'}
    }
    $failure=$null
    try { & $target @argsToUse | Out-Null } catch {$failure=$_.Exception.Message}
    if(($case -eq 'Valid') -eq [bool]$failure){throw "FAIL $case : $failure"}
    Write-Output "PASS $case"
}