// =============================================================================
//  main.bicep — subscription-scope entry point
// =============================================================================
//
//  RUN:
//    az deployment sub create \
//      --location <region> \
//      --template-file infra/main.bicep \
//      --parameters infra/main.parameters.dev.json   # or .prod.json
//
//  WHAT IT DOES:
//    1. Creates (or reuses) a resource group.
//    2. Invokes resources.bicep inside that group to create everything else.
//
//  LEGEND used throughout this file and resources.bicep:
//    [YOURS]    — A value YOU pick. Renaming/changing it is fine.
//    [FIXED]    — A literal string Azure REQUIRES exactly as written. Changing
//                 it will cause the deployment to fail (e.g. SKU codes, role
//                 definition GUIDs, OIDC issuer URL).
//    [PROPERTY] — A reserved Bicep/ARM property name. You can't rename the
//                 left side ("name:", "location:", "sku:", ...), but the value
//                 on the right side may be customizable.
// =============================================================================

// 'targetScope' tells Bicep where this template deploys. Subscription scope
// is what allows the file to create a resource group (RGs live above any
// single RG, hence the subscription level).
// [PROPERTY] targetScope — required at the top of any non-RG-scope template.
// [FIXED]    'subscription' — must be one of: 'resourceGroup' (default),
//            'subscription', 'managementGroup', 'tenant'.
targetScope = 'subscription'

// -----------------------------------------------------------------------------
// PARAMETERS — values you supply at deploy time (via the per-environment
// main.parameters.<env>.json files or with extra --parameters key=value flags).
// -----------------------------------------------------------------------------

@description('Azure region for all resources. Must support Flex Consumption (westus2, eastus, eastus2, westeurope, etc.).')
// [YOURS] — any Flex-supported Azure region. Default 'westus2' is just a
// sensible starting point; override in main.parameters.<env>.json.
param location string = 'westus2'

@description('Workload name woven into every resource name. This is the "what does it do" word, e.g. products. (2-12 chars, lowercase alphanumeric.)')
@minLength(2)
@maxLength(12)
// [YOURS] — appears in every resource name (storage, plan, function app, ...).
// Keep it short because Azure has strict length limits on some names
// (storage = 24 chars, app names = 60). For this app it is 'products'.
param workloadName string = 'products'

@description('Deployment environment. Woven into every resource name so dev/test/prod are easy to tell apart.')
@allowed([
  'dev'
  'test'
  'staging'
  'prod'
])
// [YOURS] — the environment segment. Final names look like func-products-dev-<hash>.
param environment string = 'dev'

@description('Name of the resource group to create (or reuse if it already exists in this subscription).')
// [YOURS] — defaults to 'rg-<workload>-<env>' (e.g. rg-products-dev) following the
// <type>-<workload>-<env> convention. The 'rg-' prefix is convention, not required.
param resourceGroupName string = 'rg-${workloadName}-${environment}'

@description('GitHub repository the federated credential will trust, in "owner/repo" form.')
// [YOURS] — the GitHub repo allowed to deploy via OIDC. Format is enforced by
// GitHub's OIDC subject claim; the 'owner/repo' shape is [FIXED].
param githubRepository string

@description('GitHub Actions environment authorized to deploy via OIDC. Must match `environment:` in the workflow.')
// [YOURS] — defaults to 'production'. If you change this here, also change
// the `environment:` line in .github/workflows/deploy.yml; the two must match
// for the OIDC subject claim to validate.
param githubEnvironment string = 'production'

@description('PostgreSQL connection string. Wired into the Function App as DATABASE_URL.')
@secure()
// [YOURS] — any reachable Postgres connection string. @secure() tells Bicep
// not to print the value in deployment logs.
// [PROPERTY] @secure — Bicep decorator; can't be renamed.
param databaseUrl string

// -----------------------------------------------------------------------------
// API Management parameters
// -----------------------------------------------------------------------------

@description('Contact email shown on the APIM portal. Must be syntactically valid; Azure does not verify deliverability.')
// [YOURS] — any valid-looking email address.
param apimPublisherEmail string

@description('Publisher/organization name displayed on the APIM portal.')
// [YOURS] — any string. Defaults to the workloadName for convenience.
param apimPublisherName string = workloadName

@description('When true, APIM enforces validate-jwt on every request. Leave false until the JWT params below are filled in, otherwise every request returns 401.')
// [YOURS] — bool. Default false so the initial deploy succeeds with empty
// JWT params; flip to true after configuring your identity provider.
param jwtValidationEnabled bool = false

@description('OpenID Connect metadata URL. Okta example: https://<org>.okta.com/oauth2/default/.well-known/openid-configuration')
// [YOURS] — required only when jwtValidationEnabled=true.
param openIdConfigUrl string = ''

@description('Expected JWT issuer (iss claim). Okta example: https://<org>.okta.com/oauth2/default')
// [YOURS] — required only when jwtValidationEnabled=true.
param jwtIssuerUrl string = ''

@description('Expected JWT audience (aud claim). Okta default: api://default (or whatever you configured on the authorization server).')
// [YOURS] — required only when jwtValidationEnabled=true.
param jwtAudience string = ''

// -----------------------------------------------------------------------------
// RESOURCE GROUP — the container everything else lives in.
// -----------------------------------------------------------------------------

// [PROPERTY] resource — Bicep keyword to declare an Azure resource.
// [PROPERTY] 'Microsoft.Resources/resourceGroups@2021-04-01' — the FULL resource
//            type id + API version. Type id is [FIXED] by Azure; the API version
//            (the bit after '@') controls which features are available. Newer
//            versions exist; '2021-04-01' is stable.
// [YOURS]    rg — the symbolic name used elsewhere in this file. Has nothing
//            to do with the actual Azure resource name.
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: resourceGroupName  // [PROPERTY] 'name' — required. Value is [YOURS] via param.
  location: location       // [PROPERTY] 'location' — required. Value is [YOURS].
}

// -----------------------------------------------------------------------------
// MODULE — dispatches to resources.bicep at RG scope.
// -----------------------------------------------------------------------------
// A 'module' is just another Bicep file invoked like a function. We use one
// here because resources.bicep deploys at resource-group scope, but main.bicep
// is at subscription scope — only modules can bridge the two.

// [PROPERTY] module — Bicep keyword.
// [YOURS]    resources — symbolic name.
// [YOURS]    'resources.bicep' — file path relative to main.bicep.
module resources 'resources.bicep' = {
  // 'name' here is the name of the DEPLOYMENT (visible in the Azure portal
  // under "Deployments"), not the name of any resource. [YOURS].
  name: 'resources-${workloadName}-${environment}'
  // 'scope' targets the module at the resource group we just created.
  // [PROPERTY] scope — Bicep keyword. The 'rg' reference is [YOURS] (matches
  // the symbolic name above).
  scope: rg
  // 'params' maps values into resources.bicep's parameters. The keys on the
  // left ARE [PROPERTY]-style — they must exactly match the parameter names
  // declared in resources.bicep. The values on the right are passed through.
  params: {
    location: location
    workloadName: workloadName
    environment: environment
    githubRepository: githubRepository
    githubEnvironment: githubEnvironment
    databaseUrl: databaseUrl
    apimPublisherEmail: apimPublisherEmail
    apimPublisherName: apimPublisherName
    jwtValidationEnabled: jwtValidationEnabled
    openIdConfigUrl: openIdConfigUrl
    jwtIssuerUrl: jwtIssuerUrl
    jwtAudience: jwtAudience
  }
}

// -----------------------------------------------------------------------------
// OUTPUTS — values returned to the CLI after deployment, e.g. via:
//   az deployment sub show --name <deployment-name> --query properties.outputs
// -----------------------------------------------------------------------------
// You wire most of these into GitHub repository Variables so the workflow
// knows where to deploy and how to authenticate.

// [PROPERTY] output — Bicep keyword.
// [YOURS]    resourceGroupName — the output name (free choice).
// [PROPERTY] string — the output's type.
output resourceGroupName string = rg.name
output functionAppName string = resources.outputs.functionAppName        // → GitHub var AZURE_FUNCTIONAPP_NAME
output functionAppHostname string = resources.outputs.functionAppHostname
output azureClientId string = resources.outputs.azureClientId            // → GitHub var AZURE_CLIENT_ID
// subscription() and subscription().tenantId are Bicep [PROPERTY] built-ins;
// they return facts about the deployment target, not values you set.
output azureTenantId string = subscription().tenantId                    // → GitHub var AZURE_TENANT_ID
output azureSubscriptionId string = subscription().subscriptionId        // → GitHub var AZURE_SUBSCRIPTION_ID
output apimName string = resources.outputs.apimName                      // APIM service name
output apimGatewayUrl string = resources.outputs.apimGatewayUrl          // Public gateway URL (use this as your new API base)
