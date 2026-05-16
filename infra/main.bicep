// Subscription-scope deployment: creates the resource group and dispatches to resources.bicep.
//
//   az deployment sub create \
//     --location <region> \
//     --template-file infra/main.bicep \
//     --parameters infra/main.parameters.json

targetScope = 'subscription'

@description('Azure region for all resources. Must support Flex Consumption (westus2, eastus, eastus2, westeurope, etc.).')
param location string = 'westus2'

@description('Short, lowercase prefix used to derive resource names (3-12 chars, alphanumeric).')
@minLength(3)
@maxLength(12)
param namePrefix string

@description('Name of the resource group to create (or reuse if it already exists in this subscription).')
param resourceGroupName string = 'rg-${namePrefix}'

@description('GitHub repository the federated credential will trust, in "owner/repo" form.')
param githubRepository string

@description('GitHub Actions environment authorized to deploy via OIDC. Must match `environment:` in the workflow.')
param githubEnvironment string = 'production'

@description('PostgreSQL connection string. Wired into the Function App as DATABASE_URL.')
@secure()
param databaseUrl string

resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName
  location: location
}

module resources 'resources.bicep' = {
  name: 'resources-${namePrefix}'
  scope: rg
  params: {
    location: location
    namePrefix: namePrefix
    githubRepository: githubRepository
    githubEnvironment: githubEnvironment
    databaseUrl: databaseUrl
  }
}

output resourceGroupName string = rg.name
output functionAppName string = resources.outputs.functionAppName
output functionAppHostname string = resources.outputs.functionAppHostname
output azureClientId string = resources.outputs.azureClientId
output azureTenantId string = subscription().tenantId
output azureSubscriptionId string = subscription().subscriptionId
