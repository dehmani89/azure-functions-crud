# Infrastructure (Bicep)

This directory provisions the Azure resources required to host `azure-functions-crud`. The build target is **Flex Consumption** Azure Functions deployed by **GitHub Actions via OIDC** to a Postgres database **you supply** (the Bicep does not create a database).

## What gets created

| Resource | Purpose |
|---|---|
| Resource group | Container for everything below |
| Storage account (Standard_LRS, StorageV2) | `AzureWebJobsStorage` + deployment package container (`app-package`) |
| Log Analytics workspace | Backing store for Application Insights |
| Application Insights | Logs/metrics/traces (wired in via `host.json`) |
| App Service Plan (`FC1` / FlexConsumption) | Hosting plan |
| Function App (`functionapp,linux`, Node 20) | Runs the CRUD API |
| User-assigned managed identity | Identity GitHub Actions impersonates via OIDC |
| Federated identity credential | Trusts `repo:<owner>/<repo>:environment:production` (matches the workflow's `environment:` claim) |
| Role assignment: Website Contributor | On the Function App — lets the workflow deploy code |
| Role assignment: Storage Blob Data Contributor | On the storage account — lets the workflow upload the package |
| **API Management (Consumption tier)** | Public gateway in front of the Function App with optional `validate-jwt` policy. URL: `https://<apim>.azure-api.net/api/...` |

App settings configured on the Function App: `AzureWebJobsStorage`, `DEPLOYMENT_STORAGE_CONNECTION_STRING`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `DATABASE_URL`, `NODE_ENV=production`.

### Routing

```
                    /healthcheck  ──── public (no JWT) ─────┐
Internet                                                    │
   │                                                        │
   ▼  https://<apim>.azure-api.net/api/...                  │
[ APIM Consumption ]                                        │
   │     │                                                  │
   │     └── /api/products/*  ── validate-jwt (Okta) ──┐    │
   │                                                   │    │
   ▼  https://<func>.azurewebsites.net/api/...         ▼    ▼
[ Function App ] ─────────────────────────────────────── …
   │
   ▼
[ PostgreSQL ]
```

- **`/api/healthcheck`** is intentionally public — its APIM operation has an override policy with no `<base />` in `<inbound>`, which skips the API-level JWT check.
- **`/api/products/*`** inherits the API-level `validate-jwt` policy. When `jwtValidationEnabled=true`, every request must carry a valid Okta Bearer token or APIM returns `401 Unauthorized` before the request ever reaches the Function App.

The Function App's hostname remains publicly reachable for now (the only way to lock it down is to switch the functions to `authLevel: 'function'` or add IP restrictions for APIM's outbound IPs — out of scope for this POC).

## Files

- `main.bicep` — subscription-scope entry point. Creates the resource group and dispatches to `resources.bicep`.
- `resources.bicep` — RG-scope module. Provisions everything listed above.
- `main.parameters.json` — placeholder values. **Set `databaseUrl` to a real connection string before deploying** (or pass it inline with `--parameters databaseUrl=…`).

## Prerequisites

- An Azure subscription with permission to create resource groups and role assignments.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az --version` ≥ 2.60).
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (bundled with recent `az`).
- An existing PostgreSQL database reachable from Azure (Azure Database for PostgreSQL, Supabase, Neon, RDS, etc.), with a connection string of the form:
  `postgresql://<user>:<password>@<host>:5432/<db>?sslmode=require`.
- Your GitHub repository (already wired up): `dehmani89/azure-functions-crud`.

## One-time bootstrap

The order matters: create the GitHub environment **before** running Bicep, otherwise the federated credential won't match anything the workflow can present.

### Step 1 — Create the `production` environment in GitHub

In `dehmani89/azure-functions-crud` → **Settings → Environments → New environment** → name it `production`. No protection rules required for a POC. This is what makes GitHub Actions emit the `repo:…:environment:production` OIDC subject the federated credential trusts.

### Step 2 — Allow the Function App to reach your Postgres server

On your Azure Database for PostgreSQL Flexible Server → **Networking** → enable **"Allow public access from any Azure service within Azure to this server"** (POC-friendly), or add the Function App's outbound IPs as explicit firewall rules. Without this, the API returns 500s on every route except `/healthcheck`.

### Step 3 — Deploy the infrastructure

```bash
# Log in
az login
az account set --subscription <subscription-id>

# (Optional) Adjust namePrefix / githubRepository / githubEnvironment in infra/main.parameters.json.
# Do NOT put your real Postgres password in this file — it's committed to the repo.
# Pass it inline on the command line instead (next command).

# Deploy. The inline databaseUrl override keeps the real connection string out of git.
az deployment sub create \
  --location westus2 \
  --name azfn-crud-bootstrap \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json \
  --parameters databaseUrl='postgresql://<user>:<password>@<host>:5432/<db>?sslmode=require'

# Capture outputs
az deployment sub show \
  --name azfn-crud-bootstrap \
  --query properties.outputs \
  --output json
```

### Why the inline override?

The committed `infra/main.parameters.json` keeps `databaseUrl` as a `REPLACE_ME` placeholder so the file is safe to version-control. Any value passed via a second `--parameters key=value` flag wins over the file, so the real connection string is supplied only at deploy time. Two equally good alternatives:

- **Keep an untracked overrides file.** Create `infra/main.parameters.local.json` (already covered by gitignoring it, or add `infra/main.parameters.local.json` to `.gitignore`) with just `{ "parameters": { "databaseUrl": { "value": "postgresql://…" } } }`, then pass `--parameters infra/main.parameters.local.json` after the committed one.
- **Read from an environment variable** at deploy time:
  ```bash
  az deployment sub create ... \
    --parameters databaseUrl="$DATABASE_URL"
  ```

Outputs you'll need for GitHub:

| Output | Goes into GitHub repo |
|---|---|
| `azureClientId` | Variable `AZURE_CLIENT_ID` |
| `azureTenantId` | Variable `AZURE_TENANT_ID` |
| `azureSubscriptionId` | Variable `AZURE_SUBSCRIPTION_ID` |
| `functionAppName` | Variable `AZURE_FUNCTIONAPP_NAME` |

### Step 4 — Configure GitHub repo variables

**Settings → Secrets and variables → Actions → Variables → New repository variable**, add each of the four above. These are **variables**, not secrets — they're identifiers, not credentials. The OIDC token issued at workflow runtime is what actually authenticates.

### Step 5 — Deploy code

Push to `main` (or run the workflow manually from the Actions tab). The workflow at `.github/workflows/deploy.yml`:

1. Installs production dependencies (`npm ci --omit=dev`).
2. Logs in to Azure via OIDC using the user-assigned MI (subject `repo:…:environment:production`).
3. Deploys the zip package with `Azure/functions-action@v1` (`sku: flexconsumption`).
4. Smoke-tests `https://<functionAppName>.azurewebsites.net/api/healthcheck`.

## Verify the deployment

Once the workflow shows a green check, hit the public endpoints. After adding APIM you can use either entry point:

```bash
# Direct Function App URL (always reachable)
FUNC=<functionAppName>                                  # e.g. func-prodcrud-j3xqdaliqzms4
curl -i https://$FUNC.azurewebsites.net/api/healthcheck

# APIM gateway URL (use this once APIM is provisioned)
APIM_URL=$(az deployment sub show --name azfn-crud-bootstrap --query properties.outputs.apimGatewayUrl.value -o tsv)
curl -i $APIM_URL/api/healthcheck
curl -s $APIM_URL/api/products | jq '. | length'
```

If `/healthcheck` returns 200 but `/products` returns 500, that's almost always the Postgres firewall (see Step 2). Application Insights → Failures will show the exact connection error.

## Enabling JWT validation with Okta

By default `jwtValidationEnabled` is `false` so APIM is a transparent passthrough. **`/api/healthcheck` is permanently exempt** (it carries an operation-level policy override that skips the API-level JWT check). All other routes (`/api/products/*`) require a valid Bearer token once JWT enforcement is on.

### 1. Set up an Okta authorization server + API

In the Okta admin console:

- **Security → API → Authorization Servers.** You can use the built-in `default` server or create a new one (e.g. `products-api`). Note its **Issuer URI** — it looks like `https://<your-org>.okta.com/oauth2/default` or `https://<your-org>.okta.com/oauth2/<auth-server-id>`.
- **Audience** is configured on the authorization server itself (Settings tab). The default is `api://default`. Change it to something specific to this API, e.g. `api://products`, if you want.
- (Optional) **Scopes** tab — define a scope like `products.read` if you plan to do scope-based authorization later.

### 2. Fill in `infra/main.parameters.json`

Replace the four JWT-related parameters with your Okta values:

```jsonc
"jwtValidationEnabled":  { "value": true                                                                       },
"openIdConfigUrl":       { "value": "https://<your-org>.okta.com/oauth2/default/.well-known/openid-configuration" },
"jwtIssuerUrl":          { "value": "https://<your-org>.okta.com/oauth2/default"                                  },
"jwtAudience":           { "value": "api://default"                                                              }
```

If you created a custom authorization server, swap `default` for its ID in all three URLs and use your custom audience.

### 3. Redeploy

```bash
az deployment sub create \
  --location westus2 \
  --name azfn-crud-bootstrap \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.json \
  --parameters databaseUrl='postgresql://...'
```

Bicep updates the APIM policy in place — the next request to `/api/products/*` will be rejected without a token. `/api/healthcheck` continues to work unauthenticated.

### 4. Test

```bash
APIM_URL=$(az deployment sub show --name azfn-crud-bootstrap --query properties.outputs.apimGatewayUrl.value -o tsv)

# Public — always works
curl -i $APIM_URL/api/healthcheck

# Protected — without token: 401
curl -i $APIM_URL/api/products

# Protected — with a valid Okta access token: 200
# (use the OAuth client of your choice to get a token; example with `okta` CLI:
#    okta apps:tokens get --app=<app-id>
# or via password grant / client credentials with curl + your auth server's token endpoint)
TOKEN=<paste-okta-access-token>
curl -i -H "Authorization: Bearer $TOKEN" $APIM_URL/api/products
```

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| 401 with `IP forbidden` or `Token is not yet valid` | Clock skew between client and Okta — ensure system time is correct. |
| 401 with `JWT validation failed` and `Claim value mismatch: aud` | `jwtAudience` doesn't match the `aud` claim in the token. Decode the JWT at jwt.io and compare. |
| 401 with `Unable to retrieve OpenID Connect metadata` | `openIdConfigUrl` is wrong, or your Okta org is private and APIM can't reach it (Consumption tier is public-internet only). |
| Healthcheck also returns 401 | The operation-level override policy didn't deploy. Check `apiOps[healthcheck-get]/policy` in the portal — its `<inbound>` should NOT contain `<base />`. |

## Updating infrastructure

Re-run the same `az deployment sub create` command — it's idempotent. Bicep will only touch resources that changed.

## Trusting additional environments or branches

The federated credential is bound to a GitHub Actions **environment** (default: `production`) so OIDC trust matches what GitHub presents when `environment: production` is set on the workflow job. To trust additional callers, add another `federatedIdentityCredentials` resource in `resources.bicep` with a different `subject`:

- another environment: `repo:<owner>/<repo>:environment:staging`
- a branch (when the workflow job has no `environment:`): `repo:<owner>/<repo>:ref:refs/heads/main`
- a pull request: `repo:<owner>/<repo>:pull_request`

The subject claim GitHub actually sends shows up in the failed `azure/login` log line under `subject claim - …`; matching that string is the fix for `AADSTS700213`.

## Tear-down

```bash
az group delete --name <resourceGroupName> --yes --no-wait
```

This removes everything Bicep created. Your external Postgres database is untouched.

## Cost notes (rough, westus2, idle POC)

- Flex Consumption: pay-per-execution + ~$0.000016/GB-s memory. Idle = $0.
- Storage account (LRS, minimal data): < $1/mo.
- Log Analytics + App Insights: free tier covers ~5GB/mo ingest; expect < $1/mo at POC volume.
- APIM Consumption: $0 idle, ~$3.50 per million calls.
- Total floor: a few dollars/month at low traffic.

> APIM Consumption provisions in ~5-10 minutes on first deploy. Subsequent deploys are fast (just policy/operation updates). If you re-run the deployment and the APIM service hasn't fully provisioned yet, ARM will wait until it's ready.
