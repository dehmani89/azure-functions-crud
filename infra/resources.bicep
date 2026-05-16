// Resource-group-scope deployment: provisions storage, monitoring, the Flex Consumption
// Function App, and a user-assigned managed identity for GitHub Actions OIDC.

@description('Azure region')
param location string

@description('Short, lowercase prefix used to derive resource names.')
param namePrefix string

@description('GitHub repo trusted by the federated credential, "owner/repo".')
param githubRepository string

@description('Name of the GitHub Actions environment that gates production deploys. Must match `environment:` in the workflow.')
param githubEnvironment string

@description('PostgreSQL connection string. Stored as DATABASE_URL app setting.')
@secure()
param databaseUrl string

var resourceToken = uniqueString(resourceGroup().id, namePrefix)

var storageName = toLower(take('st${namePrefix}${resourceToken}', 24))
var planName = take('plan-${namePrefix}-${resourceToken}', 40)
var functionAppName = take('func-${namePrefix}-${resourceToken}', 60)
var lawName = take('log-${namePrefix}-${resourceToken}', 63)
var aiName = take('appi-${namePrefix}-${resourceToken}', 260)
var identityName = 'id-${namePrefix}-gh-deploy'
var deploymentContainerName = 'app-package'

// -------------------------------------------------------------------------
// Storage account (deployment package + AzureWebJobsStorage)
// -------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true
    defaultToOAuthAuthentication: false
    publicNetworkAccess: 'Enabled'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName
  properties: {
    publicAccess: 'None'
  }
}

// -------------------------------------------------------------------------
// Observability: Log Analytics workspace + Application Insights
// -------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: law.id
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// -------------------------------------------------------------------------
// Flex Consumption hosting plan
// -------------------------------------------------------------------------
resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  kind: 'functionapp'
  sku: {
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    reserved: true
  }
}

// -------------------------------------------------------------------------
// Function App (Flex Consumption, Node 20)
// -------------------------------------------------------------------------
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    functionAppConfig: {
      deployment: {
        storage: {
          type: 'blobContainer'
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            type: 'StorageAccountConnectionString'
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      runtime: {
        name: 'node'
        version: '20'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100
        instanceMemoryMB: 2048
      }
    }
    siteConfig: {
      appSettings: [
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: storageConnectionString
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          name: 'DATABASE_URL'
          value: databaseUrl
        }
        {
          name: 'NODE_ENV'
          value: 'production'
        }
      ]
    }
  }
  dependsOn: [
    deploymentContainer
  ]
}

// -------------------------------------------------------------------------
// GitHub Actions OIDC: user-assigned managed identity + federated credential
// -------------------------------------------------------------------------
resource githubIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

resource githubFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: githubIdentity
  name: 'github-${githubEnvironment}'
  properties: {
    issuer: 'https://token.actions.githubusercontent.com'
    audiences: [
      'api://AzureADTokenExchange'
    ]
    subject: 'repo:${githubRepository}:environment:${githubEnvironment}'
  }
}

// Website Contributor role — lets the workflow zip-deploy to the Function App.
var websiteContributorRoleId = 'de139f84-1756-47ae-9be6-808fbbe84772'

resource githubRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: functionApp
  name: guid(functionApp.id, githubIdentity.id, websiteContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', websiteContributorRoleId)
    principalId: githubIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// Storage Blob Data Contributor on the storage account, so the workflow can
// upload deployment packages directly when the action uses identity auth.
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource githubStorageRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storage
  name: guid(storage.id, githubIdentity.id, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: githubIdentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output azureClientId string = githubIdentity.properties.clientId
output storageAccountName string = storage.name
output appInsightsName string = appInsights.name
