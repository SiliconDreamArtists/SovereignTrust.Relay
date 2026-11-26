@{
    Repository = 'SiliconDreamArtists/SovereignTrust.Relay'
    WorkflowPath = '.github/workflows/manual_deploy_sda-relay.yml'
    ControlRef = 'refs/heads/main'
    TenantId = '8904b745-1738-426c-ad85-3fcecb32d24b'
    Issuer = 'https://token.actions.githubusercontent.com'
    Audience = 'api://AzureADTokenExchange'
    Package = @{
        BuildWorkflowPath = '.github/workflows/main_publish_sda-relay-dev.yml'
        SourceCommit = 'f0325ec5133d333217c92208d19a5922bedfbb00'
        SourceTree = '81fead85696127e2b9406da4412f422b0d068939'
        SourceRef = 'refs/heads/main'
        BuildRunId = '45788694095'
        ArtifactId = '15101132737'
        ArtifactName = 'relay-manual-package'
        WrapperSha256 = '6DF744213B1798A97737C5E966D140A65356226D7FB07B2BC613E3F9C0D7B096'
        Sha256 = '586EEF9E48BAC9C01D5E4E0C342C220520A84892D389B6985B4788A7D41CABBB'
    }
    Stages = @{
        dev = @{
            Environment = 'sda-dev'; Subscription = 'cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8'; Group = 'sda-dev'
            AppName = 'sda-relay-api-dev'; PlanName = 'ASP-sda-dev-fusion'; Sku = 'B2'
            JobKey = 'deploy_dev'; JobName = 'Relay deployment dev'; Predecessor = ''
            DeploymentClientId = '8b487a0d-ff5b-4c8b-af47-df5de45c9ebd'; DeploymentPrincipalId = '3a48ab88-5916-4e2a-b7cb-94132372e1e7'; RuntimePrincipalId = '9697fed0-6ae1-462f-b372-152fd3e16184'; DefaultHostName = 'sda-relay-api-dev.azurewebsites.net'
        }
        test = @{
            Environment = 'sda-test'; Subscription = '5c813ecc-3c19-44de-b676-304116fc869d'; Group = 'sda-test'
            AppName = 'sda-relay-api-test'; PlanName = 'ASP-sda-test-fusion'; Sku = 'B1'
            JobKey = 'deploy_test'; JobName = 'Relay deployment test'; Predecessor = 'dev'
            DeploymentClientId = '52289819-53b8-48b7-a690-4dd88ff297bc'; DeploymentPrincipalId = '4c9457de-890d-46b1-9dd1-e56ecbe568bd'; RuntimePrincipalId = '1ed9a5c6-d93c-4c8b-b40e-bf484c2d1999'; DefaultHostName = 'sda-relay-api-test.azurewebsites.net'
        }
        prod = @{
            Environment = 'sda-prod'; Subscription = 'b7690041-454b-472b-b340-3d8dde115103'; Group = 'sda-prod'
            AppName = 'sda-relay-api-prod'; PlanName = 'ASP-sda-prod-fusion'; Sku = 'B3'
            JobKey = 'deploy_prod'; JobName = 'Relay deployment prod'; Predecessor = 'test'
            DeploymentClientId = ''; DeploymentPrincipalId = ''; RuntimePrincipalId = ''; DefaultHostName = ''
        }
    }
}
