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

App settings configured on the Function App: `AzureWebJobsStorage`, `DEPLOYMENT_STORAGE_CONNECTION_STRING`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `DATABASE_URL`, `NODE_ENV=production`.

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

Once the workflow shows a green check, hit the public endpoints:

```bash
APP=<functionAppName>        # e.g. func-prodcrud-j3xqdaliqzms4
BASE="https://$APP.azurewebsites.net/api"

curl -i $BASE/healthcheck                     # 200 {"status":"Service Up 2"}
curl -s $BASE/products | jq '. | length'      # row count from your Postgres
curl -s -X POST $BASE/products \
  -H "Content-Type: application/json" \
  -d '{"name":"Test","description":"smoke","price":1.00}' | jq
```

If `/healthcheck` returns 200 but `/products` returns 500, that's almost always the Postgres firewall (see Step 2). Application Insights → Failures will show the exact connection error.

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
- Total floor: a few dollars/month at low traffic.
