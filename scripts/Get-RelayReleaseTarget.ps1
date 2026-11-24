param([Parameter(Mandatory)][ValidateSet('dev','test','prod')][string]$Stage,[switch]$ValidateControl,[switch]$RequireOwner)
$ErrorActionPreference='Stop'
$Stage=$Stage.ToLowerInvariant()
$contract=Import-PowerShellDataFile (Join-Path $PSScriptRoot 'Relay.Release.psd1')
$row=$contract.Stages[$Stage]
if($ValidateControl -or $RequireOwner){
    if($env:GITHUB_REPOSITORY -cne $contract.Repository -or $env:GITHUB_EVENT_NAME -cne 'workflow_dispatch' -or
       $env:GITHUB_REF -cne $contract.ControlRef -or $env:GITHUB_SHA -cnotmatch '^[a-f0-9]{40}$' -or
       $env:GITHUB_RUN_ID -notmatch '^[1-9][0-9]*$'){throw 'Invalid deployment control context/ref.'}
    $json=& gh api "repos/$($contract.Repository)/actions/runs/$env:GITHUB_RUN_ID"
    if($LASTEXITCODE){throw 'Cannot authenticate current control run'}
    $run=($json -join "`n")|ConvertFrom-Json
    if($run.repository.full_name -cne $contract.Repository -or $run.path -cne $contract.WorkflowPath -or
       $run.event -cne 'workflow_dispatch' -or $run.head_sha -cne $env:GITHUB_SHA -or
       ('refs/heads/'+$run.head_branch) -cne $contract.ControlRef){throw 'Current control run metadata differs from Actions context.'}
}
if($RequireOwner){
    foreach($field in @('DeploymentClientId','DeploymentPrincipalId','RuntimePrincipalId')){
        if($row[$field] -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$'){throw "Owner packet is unbound: $field"}
    }
    if($row.DefaultHostName -notmatch '^[a-z0-9-]+\.[a-z0-9.-]*azurewebsites\.net$'){
        throw 'Owner default hostname is missing.'
    }
    if($env:RELAY_AZURE_CLIENT_ID -cne $row.DeploymentClientId -or $env:RELAY_AZURE_TENANT_ID -cne $contract.TenantId -or
       $env:RELAY_AZURE_SUBSCRIPTION_ID -cne $row.Subscription){throw 'Environment OIDC identity does not match fixed owner profile.'}
    if($row.Predecessor -and ($env:RELAY_PREVIOUS_ACCEPTED_RUN_ID -notmatch '^[1-9][0-9]*$' -or
       $env:RELAY_PREVIOUS_ACCEPTED_ARTIFACT_ID -notmatch '^[1-9][0-9]*$')){
        throw 'Owner predecessor pointers are incomplete or not single exact identities.'
    }
}
$result=@{};foreach($key in $row.Keys){$result[$key]=$row[$key]}
$result.Stage=$Stage;$result.Repository=$contract.Repository;$result.ControlRef=$contract.ControlRef;$result.WorkflowPath=$contract.WorkflowPath
$result.TenantId=$contract.TenantId;$result.Package=$contract.Package
$result.AppResourceId="/subscriptions/$($row.Subscription)/resourceGroups/$($row.Group)/providers/Microsoft.Web/sites/$($row.AppName)"
$result.PlanResourceId="/subscriptions/$($row.Subscription)/resourceGroups/$($row.Group)/providers/Microsoft.Web/serverfarms/$($row.PlanName)"
$result.FederationSubject="repo:$($contract.Repository):environment:$($row.Environment)"
[pscustomobject]$result
