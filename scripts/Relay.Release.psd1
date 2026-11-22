@{
    Repository = 'SiliconDreamArtists/SovereignTrust.Relay'
    WorkflowPath = '.github/workflows/manual_deploy_sda-relay.yml'
    ControlRef = 'refs/heads/agents/relay-azure-to-aspnet-core-migration'
    TenantId = '8904b745-1738-426c-ad85-3fcecb32d24b'
    Issuer = 'https://token.actions.githubusercontent.com'
    Audience = 'api://AzureADTokenExchange'
    Package = @{
        BuildWorkflowPath = '.github/workflows/main_publish_sda-relay-dev.yml'
        SourceCommit = 'b32c3fbfe2cdf64056be264d59dcd97df6d4591e'
        SourceTree = '1dbd784e41033d3ffcce6206bef54f2b3d9ab090'
        SourceRef = 'refs/heads/agents/relay-azure-to-aspnet-core-migration'
        BuildRunId = '44994573298'
        ArtifactId = '14743586651'
        ArtifactName = 'relay-manual-package'
        WrapperSha256 = '255B70A03DB79149BEF46A9880AE51F9816CD77FD8E203D531EB4312B1B0DA8F'
        Sha256 = 'E4473862F6A6406B8DC021CFFCB34B82247AAD7640D9FE0CB3659D1A8DBB87FC'
    }
    Stages = @{
        dev = @{
            Environment = 'sda-dev'; Subscription = 'cc1fa56e-a8ce-411f-bb5c-58e96d9ac4f8'; Group = 'sda-dev'
            AppName = 'sda-relay-api-dev'; PlanName = 'ASP-sda-dev-fusion'; Sku = 'B1'
            JobKey = 'deploy_dev'; JobName = 'Relay deployment dev'; Predecessor = ''
            DeploymentClientId = ''; DeploymentPrincipalId = ''; RuntimePrincipalId = ''; DefaultHostName = ''; OwnerPacketSha256 = ''
        }
        test = @{
            Environment = 'sda-test'; Subscription = '5c813ecc-3c19-44de-b676-304116fc869d'; Group = 'sda-test'
            AppName = 'sda-relay-api-test'; PlanName = 'ASP-sda-test-fusion'; Sku = 'B1'
            JobKey = 'deploy_test'; JobName = 'Relay deployment test'; Predecessor = 'dev'
            DeploymentClientId = ''; DeploymentPrincipalId = ''; RuntimePrincipalId = ''; DefaultHostName = ''; OwnerPacketSha256 = ''
        }
        prod = @{
            Environment = 'sda-prod'; Subscription = 'b7690041-454b-472b-b340-3d8dde115103'; Group = 'sda-prod'
            AppName = 'sda-relay-api-prod'; PlanName = 'ASP-sda-prod-fusion'; Sku = 'B3'
            JobKey = 'deploy_prod'; JobName = 'Relay deployment prod'; Predecessor = 'test'
            DeploymentClientId = ''; DeploymentPrincipalId = ''; RuntimePrincipalId = ''; DefaultHostName = ''; OwnerPacketSha256 = ''
        }
    }
}
