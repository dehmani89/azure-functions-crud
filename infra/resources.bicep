// =============================================================================
//  resources.bicep — resource-group-scope deployment
// =============================================================================
//
//  Called by main.bicep as a module. Provisions every Azure resource
//  the application needs:
//    1. Storage account (deployment package + AzureWebJobsStorage)
//    2. Log Analytics workspace + Application Insights (observability)
//    3. App Service Plan (Flex Consumption SKU)
//    4. Function App (Linux, Node 20)
//    5. User-assigned managed identity + GitHub OIDC federated credential
//    6. Role assignments granting the identity permission to deploy code
//
//  See main.bicep for the LEGEND ([YOURS] / [FIXED] / [PROPERTY]).
// =============================================================================

// -----------------------------------------------------------------------------
// PARAMETERS — passed in from main.bicep.
// -----------------------------------------------------------------------------
// These declarations must match the keys in main.bicep's `module ... params: {}`.

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

// -----------------------------------------------------------------------------
// VARIABLES — computed names used by the resources below.
// -----------------------------------------------------------------------------
// `uniqueString` is a Bicep [PROPERTY] built-in. It hashes its arguments into
// a 13-character deterministic string. We use it to ensure resource names that
// must be globally unique (storage account, function app) don't collide.

// [FIXED bicep function] uniqueString(...) — Bicep built-in.
// [PROPERTY built-in]    resourceGroup().id — refers to the RG this template
//                        deploys into. Both args together mean: "the same RG +
//                        same prefix produces the same hash on every run."
var resourceToken = uniqueString(resourceGroup().id, namePrefix)

// Resource-name constants. All the strings below are [YOURS] — only the
// length/character constraints are imposed by Azure:
//   storage account: 3-24 chars, lowercase + digits only, GLOBALLY unique
//   function app:    2-60 chars, alphanumeric + hyphens, GLOBALLY unique
//   log analytics:   4-63 chars, alphanumeric + hyphens, RG-scoped
//   plan:            1-40 chars, alphanumeric + hyphens, RG-scoped
//   managed identity: 3-128 chars, alphanumeric + hyphens, RG-scoped
// `take(str, n)` truncates to n chars — protects against length violations
// when the namePrefix is near the max length.
var storageName = toLower(take('st${namePrefix}${resourceToken}', 24))
var planName = take('plan-${namePrefix}-${resourceToken}', 40)
var functionAppName = take('func-${namePrefix}-${resourceToken}', 60)
var lawName = take('log-${namePrefix}-${resourceToken}', 63)
var aiName = take('appi-${namePrefix}-${resourceToken}', 260)
var identityName = 'id-${namePrefix}-gh-deploy'
// The container the Function App reads its zipped deployment package from.
// [YOURS] — any valid container name. Azure Functions doesn't care what it's
// called; the Function App points at it explicitly below.
var deploymentContainerName = 'app-package'

// =============================================================================
// 1. STORAGE ACCOUNT
// =============================================================================
// Two jobs:
//   - Holds the deployment package (zip file with our function code).
//   - Backs AzureWebJobsStorage, which the Functions runtime uses to track
//     trigger metadata, leases, etc.
// =============================================================================

// [PROPERTY] type+API: 'Microsoft.Storage/storageAccounts@2023-05-01' is [FIXED]
//            (it identifies the Azure resource type).
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  // [FIXED] 'StorageV2' — the modern storage account kind. Other valid values
  //         include 'BlobStorage', 'FileStorage', 'BlockBlobStorage', but
  //         StorageV2 is the only one that supports everything Functions needs.
  kind: 'StorageV2'
  sku: {
    // [FIXED] 'Standard_LRS' — Locally Redundant Storage, the cheapest SKU.
    //         Other valid values: 'Standard_GRS' (geo-redundant, more $),
    //         'Standard_ZRS' (zone-redundant), 'Premium_LRS' (SSD), etc.
    name: 'Standard_LRS'
  }
  // [PROPERTY] 'properties' — required block of resource-specific settings.
  properties: {
    minimumTlsVersion: 'TLS1_2'           // [FIXED] valid: 'TLS1_0'/'TLS1_1'/'TLS1_2'. Don't use 1.0/1.1.
    supportsHttpsTrafficOnly: true        // [YOURS, but should stay true]
    allowBlobPublicAccess: false          // [YOURS, but should stay false] no public anonymous blobs
    allowSharedKeyAccess: true            // [YOURS] — needed because the Function App authenticates with the storage key (see siteConfig.appSettings below). Set to false if you switch to identity-based auth.
    defaultToOAuthAuthentication: false   // [YOURS]
    publicNetworkAccess: 'Enabled'        // [FIXED enum] 'Enabled' or 'Disabled'
  }
}

// Sub-resources use 'parent:' to attach to a parent resource. The 'name' here
// is [FIXED] to the special value 'default' for blob services — Azure only
// allows ONE blob service per storage account, and it must be named 'default'.
resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'   // [FIXED] — Azure rejects any other name here.
}

// The container we'll upload the deployment zip into.
resource deploymentContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: deploymentContainerName   // [YOURS]
  properties: {
    publicAccess: 'None'          // [FIXED enum] 'None' / 'Blob' / 'Container'
  }
}

// =============================================================================
// 2. OBSERVABILITY — Log Analytics workspace + Application Insights
// =============================================================================
// App Insights is the Azure SDK that captures logs/metrics/traces from your
// Function App. It's set up "workspace-based" mode (recommended): the
// telemetry physically lives in a Log Analytics workspace.
// =============================================================================

resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: lawName
  location: location
  properties: {
    sku: {
      // [FIXED] 'PerGB2018' — the modern pay-per-ingestion SKU. Other legacy
      //         SKUs exist ('Free', 'Standard', 'Premium') but PerGB2018 is
      //         what Microsoft currently recommends.
      name: 'PerGB2018'
    }
    retentionInDays: 30    // [YOURS] 30-730 days. Free tier covers 31 days.
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  // [FIXED] 'web' — tells App Insights to apply web-app conventions. Other
  //         options: 'ios', 'java', 'other', 'phone', 'store'.
  kind: 'web'
  properties: {
    // [FIXED enum] Application_Type — 'web' or 'other'. Note the CAPITALIZED
    //         property name: this is one of the rare Azure property names
    //         that breaks the camelCase convention.
    Application_Type: 'web'
    // [PROPERTY] WorkspaceResourceId — links App Insights to the Log Analytics
    //         workspace. Capital-W is required (Azure quirk).
    WorkspaceResourceId: law.id
    publicNetworkAccessForIngestion: 'Enabled'   // [FIXED enum]
    publicNetworkAccessForQuery: 'Enabled'       // [FIXED enum]
  }
}

// =============================================================================
// 3. FLEX CONSUMPTION HOSTING PLAN
// =============================================================================
// An App Service Plan defines the compute that hosts the Function App.
// Flex Consumption is the modern serverless tier: scales to zero, fast cold
// starts, supports VNET integration.
// =============================================================================

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  // [FIXED] 'functionapp' — required for a plan that will host Function Apps.
  kind: 'functionapp'
  sku: {
    // [FIXED] 'FlexConsumption' is the tier name; 'FC1' is the SKU name.
    //         Both are required for Flex Consumption; other valid combinations
    //         include tier='Dynamic'+name='Y1' (classic Consumption),
    //         tier='ElasticPremium'+name='EP1' (Premium), tier='Basic'+'B1' etc.
    tier: 'FlexConsumption'
    name: 'FC1'
  }
  properties: {
    // [FIXED] reserved: true — required on every Linux App Service Plan.
    //         (Naming is misleading; "reserved" here means "Linux," nothing else.)
    reserved: true
  }
}

// =============================================================================
// 4. FUNCTION APP
// =============================================================================
// The actual application. Combines:
//   - the hosting plan (compute capacity)
//   - the runtime (Node 20 in our case)
//   - a deployment storage container (where to pull the zip from)
//   - app settings (env vars, including DATABASE_URL)
// =============================================================================

// We need a connection string twice: for AzureWebJobsStorage and for the
// deployment storage. Build it once as a 'var' to avoid duplication.
// `listKeys()` is a Bicep built-in that calls the ARM list-keys API at deploy
// time to retrieve the storage account's access keys.
// [FIXED bicep function] listKeys / environment() — Bicep built-ins.
// [PROPERTY] suffixes.storage — returns 'core.windows.net' in Azure public cloud,
//            'core.usgovcloudapi.net' in Government, etc. Use the built-in so
//            the template works in any cloud.
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storage.name};AccountKey=${storage.listKeys().keys[0].value};EndpointSuffix=${environment().suffixes.storage}'

resource functionApp 'Microsoft.Web/sites@2023-12-01' = {
  name: functionAppName
  location: location
  // [FIXED] 'functionapp,linux' — required for Linux Function Apps. Plain
  //         'functionapp' is for Windows. Flex Consumption is Linux-only,
  //         so this comma-suffixed form is mandatory.
  kind: 'functionapp,linux'
  // 'identity' enables the Function App's system-assigned managed identity.
  // We use it for ARM operations the app may need (currently none, but it's
  // free and useful for future features like Key Vault).
  identity: {
    type: 'SystemAssigned'   // [FIXED enum] 'SystemAssigned' / 'UserAssigned' / 'SystemAssigned,UserAssigned' / 'None'
  }
  properties: {
    // [PROPERTY] serverFarmId — points the app at its hosting plan. The value
    //            (plan.id) is [YOURS] via the symbolic reference.
    serverFarmId: plan.id
    httpsOnly: true     // [YOURS, but should stay true] redirects http → https
    // 'functionAppConfig' is the FLEX-CONSUMPTION-SPECIFIC config block. It
    // replaces several legacy app settings (FUNCTIONS_WORKER_RUNTIME,
    // WEBSITE_RUN_FROM_PACKAGE, WEBSITE_NODE_DEFAULT_VERSION, etc.).
    functionAppConfig: {
      deployment: {
        storage: {
          // [FIXED enum] 'blobContainer' — currently the only supported value.
          type: 'blobContainer'
          // The URL of the container we created above. Note: primaryEndpoints.blob
          // ALREADY includes a trailing slash (`https://acct.blob.core.windows.net/`),
          // so concatenating the container name gives a valid URL.
          value: '${storage.properties.primaryEndpoints.blob}${deploymentContainerName}'
          authentication: {
            // [FIXED enum] valid values: 'SystemAssignedIdentity',
            //              'UserAssignedIdentity', 'StorageAccountConnectionString'.
            //              The string 'StorageAccountConnectionStringFromAppSetting'
            //              is NOT valid (despite appearing in some old docs).
            type: 'StorageAccountConnectionString'
            // [PROPERTY] field name is [FIXED]; value is [YOURS]: it must
            //            match the name of an app setting (declared below)
            //            that holds the actual connection string.
            storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          }
        }
      }
      runtime: {
        // [FIXED enum] supported: 'node', 'python', 'java', 'dotnet-isolated',
        //              'powershell', 'custom'.
        name: 'node'
        // [FIXED enum] supported Node versions: '18', '20', '22'. 'lts' is NOT
        //              accepted — must be a concrete major version.
        version: '20'
      }
      scaleAndConcurrency: {
        maximumInstanceCount: 100    // [YOURS] 40-1000 for Flex
        instanceMemoryMB: 2048       // [FIXED enum] valid: 512, 2048, 4096
      }
    }
    siteConfig: {
      // 'appSettings' is the equivalent of environment variables. Each entry's
      // 'name' becomes an env var inside the function process; access it via
      // process.env.<NAME> in JavaScript.
      appSettings: [
        {
          // [FIXED name] 'AzureWebJobsStorage' — the Functions runtime LITERALLY
          //              looks for this exact app setting name to find its
          //              metadata storage. You cannot rename it.
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        {
          // [YOURS name] this one is just a regular app setting that we
          //              defined above and referenced from
          //              functionAppConfig.deployment.storage.authentication.
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: storageConnectionString
        }
        {
          // [FIXED name] 'APPLICATIONINSIGHTS_CONNECTION_STRING' — Azure Functions
          //              auto-detects this name and wires up App Insights
          //              telemetry. Old name 'APPINSIGHTS_INSTRUMENTATIONKEY'
          //              also works but is deprecated.
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: appInsights.properties.ConnectionString
        }
        {
          // [YOURS name] — our application reads this in src/db.js.
          name: 'DATABASE_URL'
          value: databaseUrl
        }
        {
          // [FIXED name pattern] 'NODE_ENV' is Node.js convention, not Azure.
          //                       Setting it to 'production' enables SSL in
          //                       src/db.js. Many npm packages also branch on
          //                       this.
          name: 'NODE_ENV'
          value: 'production'
        }
      ]
      // IMPORTANT: Do NOT add 'FUNCTIONS_WORKER_RUNTIME' or
      // 'FUNCTIONS_EXTENSION_VERSION' app settings on Flex Consumption — the
      // deployment will be rejected. Runtime config goes in functionAppConfig
      // above. Same goes for WEBSITE_RUN_FROM_PACKAGE / WEBSITE_CONTENTSHARE /
      // WEBSITE_CONTENTAZUREFILECONNECTIONSTRING — all forbidden on Flex.
    }
  }
  // [PROPERTY] dependsOn — explicit ordering. Usually Bicep infers this from
  //            references, but the deploymentContainer URL above is a string
  //            interpolation, so Bicep can't see the dependency on its own.
  dependsOn: [
    deploymentContainer
  ]
}

// =============================================================================
// 5. GITHUB OIDC IDENTITY
// =============================================================================
// We create a user-assigned managed identity (UAMI) and configure it with
// a "federated identity credential" trusting GitHub Actions tokens. This is
// the mechanism that lets the workflow log in to Azure WITHOUT storing any
// long-lived secret.
// =============================================================================

resource githubIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
}

// The federated credential is a CHILD resource on the UAMI.
resource githubFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2023-01-31' = {
  parent: githubIdentity
  name: 'github-${githubEnvironment}'   // [YOURS] purely a label inside Azure.
  properties: {
    // [FIXED] OIDC issuer URL. GitHub publishes its OIDC tokens with exactly
    //         this 'iss' claim; if you write anything else, no GitHub token
    //         will ever match.
    issuer: 'https://token.actions.githubusercontent.com'
    audiences: [
      // [FIXED] The default audience the `azure/login@v2` GitHub Action uses.
      //         If you change the action's `audience:` input, you must change
      //         this to match.
      'api://AzureADTokenExchange'
    ]
    // [FIXED format] The `sub` claim GitHub will present, and what Azure
    //                checks against. Format pieces:
    //                   'repo:'              — literal prefix [FIXED]
    //                   '${githubRepository}'— "owner/repo" [YOURS]
    //                   ':environment:'      — literal [FIXED]
    //                   '${githubEnvironment}' — env name [YOURS]
    //                Other valid suffixes (mutually exclusive per credential):
    //                   ':ref:refs/heads/<branch>' — branch trigger w/o environment
    //                   ':pull_request'            — PR trigger
    //                   ':ref:refs/tags/<tag>'     — tag push
    subject: 'repo:${githubRepository}:environment:${githubEnvironment}'
  }
}

// -----------------------------------------------------------------------------
// 6. ROLE ASSIGNMENTS
// -----------------------------------------------------------------------------
// The identity has no permissions yet. Two role assignments grant it just
// enough to deploy code:
//   - Website Contributor on the Function App → call /publish, restart, etc.
//   - Storage Blob Data Contributor on the storage account → upload the zip
//
// Role definition GUIDs below are GLOBAL [FIXED] Azure built-in roles. They
// are the same in every subscription / tenant. You can find the full list at
// https://learn.microsoft.com/azure/role-based-access-control/built-in-roles
// -----------------------------------------------------------------------------

// [FIXED] de139f84-1756-47ae-9be6-808fbbe84772 = Website Contributor
var websiteContributorRoleId = 'de139f84-1756-47ae-9be6-808fbbe84772'

resource githubRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // [PROPERTY] scope — the resource this role applies to. We restrict it to
  //            the Function App (not the whole RG/subscription) for least
  //            privilege.
  scope: functionApp
  // 'name' for a role assignment must be a deterministic GUID. The pattern
  // guid(scope, principal, role) ensures we get the SAME guid on every deploy
  // (so it's idempotent) and a DIFFERENT one for any other assignment.
  // [FIXED bicep function] guid() — Bicep built-in.
  name: guid(functionApp.id, githubIdentity.id, websiteContributorRoleId)
  properties: {
    // 'subscriptionResourceId' builds the full ARM ID for the role definition.
    // [FIXED bicep function] subscriptionResourceId() — Bicep built-in.
    // [FIXED] 'Microsoft.Authorization/roleDefinitions' — the resource type.
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', websiteContributorRoleId)
    // 'principalId' — who gets the role. The UAMI's principalId.
    principalId: githubIdentity.properties.principalId
    // [FIXED enum] principalType — 'User', 'Group', 'ServicePrincipal',
    //              'ForeignGroup', 'Device'. Managed identities are
    //              represented as service principals.
    principalType: 'ServicePrincipal'
  }
}

// [FIXED] ba92f5b4-2d11-453d-a403-e96b0029c9fe = Storage Blob Data Contributor
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

// =============================================================================
// OUTPUTS — surfaced by main.bicep to the CLI.
// =============================================================================
// Output names are [YOURS]; main.bicep references them via `resources.outputs.<name>`.

output functionAppName string = functionApp.name
output functionAppHostname string = functionApp.properties.defaultHostName
output azureClientId string = githubIdentity.properties.clientId
output storageAccountName string = storage.name
output appInsightsName string = appInsights.name
