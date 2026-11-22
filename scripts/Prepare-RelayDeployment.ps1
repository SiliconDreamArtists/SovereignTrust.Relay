param(
    [Parameter(Mandatory)][ValidateSet('Dev','Test','Prod')][string]$Environment,
    [Parameter(Mandatory)][string]$AppResourceId,
    [Parameter(Mandatory)][string]$PlanResourceId
)
$ErrorActionPreference = 'Stop'
$contracts = @{
    Dev = @{Subscription='cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8';Group='sda-dev';Name='sda-relay-api-dev';Plan='ASP-sda-dev-fusion'}
    Test = @{Subscription='5c813ecc-3c19-44de-b676-304116fc869d';Group='sda-test';Name='sda-relay-api-test';Plan='ASP-sda-test-fusion'}
    Prod = @{Subscription='b7690041-454b-472b-b340-3d8dde115103';Group='sda-prod';Name='sda-relay-api-prod';Plan='ASP-sda-prod-fusion'}
}
$c = $contracts[$Environment]
$expectedApp = "/subscriptions/$($c.Subscription)/resourceGroups/$($c.Group)/providers/Microsoft.Web/sites/$($c.Name)"
$expectedPlan = "/subscriptions/$($c.Subscription)/resourceGroups/$($c.Group)/providers/Microsoft.Web/serverfarms/$($c.Plan)"
if ($AppResourceId -ine $expectedApp -or $PlanResourceId -ine $expectedPlan) { throw 'Environment/app/plan contract mismatch.' }
function Invoke-RelayAzureRead {
    param([string[]]$Arguments)
    $result = & az @Arguments --subscription $c.Subscription --output json --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw 'Azure read failed; no deployment authorized.' }
    if ($result) { ($result -join [Environment]::NewLine) | ConvertFrom-Json }
}
$app = Invoke-RelayAzureRead @('resource','show','--ids',$AppResourceId)
if ($app.id -ine $expectedApp -or $app.kind -notmatch 'linux' -or $app.kind -match 'functionapp' -or
    $app.properties.state -ne 'Running' -or $app.properties.serverFarmId -ine $expectedPlan -or
    $app.properties.httpsOnly -ne $true) { throw 'Target must be the exact running HTTPS Linux Relay Web App on the expected plan.' }
$config = Invoke-RelayAzureRead @('webapp','config','show','--name',$c.Name,'--resource-group',$c.Group)
if ($config.linuxFxVersion -ne 'DOTNETCORE|10.0' -or $config.alwaysOn -ne $true) { throw 'Require DOTNETCORE|10.0 and per-app Always On.' }
# Names only; never emit credential-bearing settings. Owner resolves vault references and provisions data resources.
$names = @(Invoke-RelayAzureRead @('webapp','config','appsettings','list','--name',$c.Name,'--resource-group',$c.Group,'--query','[].name'))
foreach ($required in @('DISCORD_PUBLIC_KEY','StorageQueueAccount','DISCORD_QUEUE_NAME','DISCORD_DEDUP_CONTAINER','ENABLE_ED25519_SIGNING')) {
    if ($names -cnotcontains $required) { throw "Missing required setting name: $required" }
}
$flag = Invoke-RelayAzureRead @('webapp','config','appsettings','list','--name',$c.Name,'--resource-group',$c.Group,'--query',"[?name=='ENABLE_ED25519_SIGNING'].value | [0]")
if ($flag -cne 'false') { throw 'ENABLE_ED25519_SIGNING must be exactly false for release.' }
Write-Output "Validated $Environment ordinary Relay target $expectedApp; no configuration or storage writes performed."