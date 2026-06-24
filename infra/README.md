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
| Federated identity credential | Trusts `repo:<owner>/<repo>:environment:<githubEnvironment>` — `dev` or `prod` depending on which params file you deploy (matches the workflow's `environment:` claim) |
| Role assignment: Website Contributor | On the Function App — lets the workflow deploy code |
| Role assignment: Storage Blob Data Contributor | On the storage account — lets the workflow upload the package |
| **API Management (Consumption tier)** | Public gateway in front of the Function App with optional `validate-jwt` policy. URL: `https://<apim>.azure-api.net/api/...` |

App settings configured on the Function App: `AzureWebJobsStorage`, `DEPLOYMENT_STORAGE_CONNECTION_STRING`, `APPLICATIONINSIGHTS_CONNECTION_STRING`, `DATABASE_URL`, `NODE_ENV=production`.

### Naming convention

All resource names follow `<resource-type>-<workload>-<environment>`, driven by two parameters: `workloadName` (default `products`) and `environment` (default `dev`). This keeps resources self-documenting as your subscription grows — sorting by name groups them by type, and the `-products-dev` middle tells you which app and environment at a glance. With the defaults you get:

| Resource | Name |
|---|---|
| Resource group | `rg-products-dev` |
| Storage account | `stproductsdev<hash>` (no hyphens allowed; lowercased; trailing hash trimmed to fit 24 chars) |
| Log Analytics workspace | `log-products-dev` |
| Application Insights | `appi-products-dev` |
| App Service Plan | `plan-products-dev` |
| Function App | `func-products-dev-<hash>` (globally unique → keeps hash) |
| Managed identity | `id-products-dev-ghdeploy` |
| API Management | `apim-products-dev-<hash>` (globally unique → keeps hash) |

`<hash>` is a deterministic 13-char `uniqueString(resourceGroup().id, workloadName, environment)` — the same inputs always produce the same names (idempotent), and each environment gets a distinct hash. To stand up a second environment, deploy with `--parameters environment=prod` (and a matching `resourceGroupName`); to deploy a different app, change `workloadName`.

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
- `main.parameters.dev.json` / `main.parameters.prod.json` — one per environment. They differ only in `environment` (`dev`/`prod`), `resourceGroupName` (`rg-products-dev`/`rg-products-prod`), and `githubEnvironment` (`dev`/`prod`). **Set `databaseUrl` to a real connection string before deploying** (or pass it inline with `--parameters databaseUrl=…`). Each environment should point at its own database.

## Prerequisites

- An Azure subscription with permission to create resource groups and role assignments.
- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az --version` ≥ 2.60).
- [Bicep CLI](https://learn.microsoft.com/azure/azure-resource-manager/bicep/install) (bundled with recent `az`).
- An existing PostgreSQL database reachable from Azure (Azure Database for PostgreSQL, Supabase, Neon, RDS, etc.), with a connection string of the form:
  `postgresql://<user>:<password>@<host>:5432/<db>?sslmode=require`. If you don't have one yet, see [Creating a PostgreSQL Flexible Server (Azure Portal)](#creating-a-postgresql-flexible-server-azure-portal) below.
- Your GitHub repository (already wired up): `dehmani89/azure-functions-crud`.

## Creating a PostgreSQL Flexible Server (Azure Portal)

The Bicep in this directory does **not** create a database — you supply one. If you want an Azure-native option, the recommended choice is **Azure Database for PostgreSQL — Flexible Server**. Here's how to create one in the portal.

### 1. Create the server

1. In the [Azure Portal](https://portal.azure.com), search for **Azure Database for PostgreSQL flexible servers** → **Create**.
2. **Basics** tab:
   - **Subscription / Resource group** — pick the same subscription you'll deploy the Function App into. You can reuse the app's resource group or create a separate one for data.
   - **Server name** — globally unique, e.g. `psql-products-dev`. This becomes the host `psql-products-dev.postgres.database.azure.com`.
   - **Region** — match the Function App region (`westus2` in this repo's examples) to minimize latency.
   - **PostgreSQL version** — 16 (matches local dev).
   - **Workload type** — **Development** for a POC (cheapest; you can scale up later).
   - **Compute + storage** — click **Configure server** and choose the **Burstable** tier (e.g. `Standard_B1ms`, 1 vCore / 2 GiB). Smallest storage (32 GiB) is fine for a POC.
   - **Availability zone** — No preference. Leave **High availability** disabled for a POC.
   - **Authentication method** — **PostgreSQL authentication only** (username + password). Set the **admin username** (e.g. `pgadmin`) and a strong **password** — you'll need both for the connection string.
3. **Networking** tab:
   - **Connectivity method** — **Public access (allowed IP addresses)**.
   - Check **"Allow public access to this resource through the internet using a public IP address."**
   - Check **"Allow public access from any Azure service within Azure to this server"** — this is what lets the Flex Consumption Function App reach it (POC-friendly; see Step 2 below). For tighter control, skip this and add the Function App's outbound IPs as firewall rules instead.
   - (Optional) **Add current client IP address** so you can connect with `psql` from your machine to run `sql/setup.sql`.
4. Review + create. Provisioning takes a few minutes.

### 2. Create the application database

The server ships with a default `postgres` database. Create a dedicated one for this app (matches the local `productsDB`):

- **Portal:** server → **Settings → Databases → Add** → name it `productsDB`.
- **Or via `psql`** once the server is up and your client IP is allowed:
  ```bash
  psql "postgresql://pgadmin:<password>@psql-products-dev.postgres.database.azure.com:5432/postgres?sslmode=require" \
    -c "CREATE DATABASE \"productsDB\";"
  ```

### 3. Load the schema

Run this repo's schema/seed script against the new database:

```bash
psql "postgresql://pgadmin:<password>@psql-products-dev.postgres.database.azure.com:5432/productsDB?sslmode=require" \
  -f sql/setup.sql
```

### 4. Build the connection string

Use this as the `databaseUrl` parameter in the deployment (Step 3 below). Note `sslmode=require` is **mandatory** for Azure PostgreSQL — the server rejects non-TLS connections:

```
postgresql://pgadmin:<password>@psql-products-dev.postgres.database.azure.com:5432/productsDB?sslmode=require
```

## One-time bootstrap

This app uses **two environments**, mapped from git branches by the CI/CD workflow:

| Git branch | GitHub Environment | Azure resource group | Params file |
|---|---|---|---|
| `develop` | `dev`  | `rg-products-dev`  | `main.parameters.dev.json`  |
| `main`    | `prod` | `rg-products-prod` | `main.parameters.prod.json` |

Run the bootstrap below **once per environment** (dev first, then prod). The order matters: create the GitHub Environment **before** running Bicep, otherwise the federated credential won't match anything the workflow can present.

### Step 1 — Create the `dev` and `prod` environments in GitHub

In `dehmani89/azure-functions-crud` → **Settings → Environments → New environment** → create **two** environments named exactly `dev` and `prod`. No protection rules required for a POC (you may later add a required-reviewer rule on `prod`). These names are what make GitHub Actions emit the `repo:…:environment:dev` / `repo:…:environment:prod` OIDC subjects the federated credentials trust.

### Step 2 — Allow the Function App to reach your Postgres server

On your Azure Database for PostgreSQL Flexible Server → **Networking** → enable **"Allow public access from any Azure service within Azure to this server"** (POC-friendly), or add the Function App's outbound IPs as explicit firewall rules. Without this, the API returns 500s on every route except `/healthcheck`. (If you created the server using the section above, you already enabled this in its Networking step.)

### Step 3 — Deploy the infrastructure

```bash
# Log in
az login
az account set --subscription <subscription-id>

# (Optional) Adjust workloadName / githubRepository in the params files.
# Do NOT put your real Postgres password in these files — they're committed to the repo.
# Pass it inline on the command line instead (next command).

# Deploy DEV (run from the develop-environment context). The inline databaseUrl
# override keeps the real connection string out of git.
az deployment sub create \
  --location westus2 \
  --name azfn-crud-bootstrap-dev \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.dev.json \
  --parameters databaseUrl='postgresql://<user>:<password>@<dev-host>:5432/<db>?sslmode=require'

# Deploy PROD (repeat with the prod params file + prod database)
az deployment sub create \
  --location westus2 \
  --name azfn-crud-bootstrap-prod \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.prod.json \
  --parameters databaseUrl='postgresql://<user>:<password>@<prod-host>:5432/<db>?sslmode=require'

# Capture outputs (per environment — swap the --name to -prod for the prod set)
az deployment sub show \
  --name azfn-crud-bootstrap-dev \
  --query properties.outputs \
  --output json
```

### Why the inline override?

The committed `infra/main.parameters.<env>.json` files keep `databaseUrl` as a `REPLACE_ME` placeholder so they're safe to version-control. Any value passed via a second `--parameters key=value` flag wins over the file, so the real connection string is supplied only at deploy time. Two equally good alternatives:

- **Keep an untracked overrides file.** Create `infra/main.parameters.local.json` (already covered by gitignoring it, or add `infra/main.parameters.local.json` to `.gitignore`) with just `{ "parameters": { "databaseUrl": { "value": "postgresql://…" } } }`, then pass `--parameters infra/main.parameters.local.json` after the committed one.
- **Read from an environment variable** at deploy time:
  ```bash
  az deployment sub create ... \
    --parameters databaseUrl="$DATABASE_URL"
  ```

Outputs you'll need for GitHub (capture these from **each** environment's deployment — the values differ between dev and prod):

| Output | GitHub variable |
|---|---|
| `azureClientId` | `AZURE_CLIENT_ID` |
| `azureTenantId` | `AZURE_TENANT_ID` |
| `azureSubscriptionId` | `AZURE_SUBSCRIPTION_ID` |
| `functionAppName` | `AZURE_FUNCTIONAPP_NAME` |

### Step 4 — Configure GitHub **environment-scoped** variables

Set these as **environment** variables (not repository-wide), so the same `vars.AZURE_*` references in the workflow resolve to the right values per branch:

**Settings → Environments → `dev` → Environment variables → Add variable** — add all four using the **dev** deployment's outputs. Then repeat for the **`prod`** environment using the **prod** deployment's outputs.

These are **variables**, not secrets — they're identifiers, not credentials. The OIDC token issued at workflow runtime is what actually authenticates. (`AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID` are usually identical across environments; `AZURE_CLIENT_ID` and `AZURE_FUNCTIONAPP_NAME` differ because each environment has its own managed identity and Function App.)

### Step 5 — Deploy code

Push to a branch (or run the workflow manually from the Actions tab). The branch decides the target environment:

- push to **`develop`** → deploys to the **`dev`** environment.
- push to **`main`** → deploys to the **`prod`** environment.

The workflow at `.github/workflows/deploy.yml`:

1. Installs production dependencies (`npm ci --omit=dev`).
2. Selects the GitHub Environment via `environment: ${{ github.ref == 'refs/heads/main' && 'prod' || 'dev' }}`, so `vars.AZURE_*` resolve to that environment's values.
3. Logs in to Azure via OIDC using that environment's user-assigned MI (subject `repo:…:environment:dev` or `…:prod`).
4. Deploys the zip package with `Azure/functions-action@v1` (`sku: flexconsumption`).
5. Smoke-tests `https://<functionAppName>.azurewebsites.net/api/healthcheck`.

## Verify the deployment

Once the workflow shows a green check, hit the public endpoints. After adding APIM you can use either entry point:

```bash
# Direct Function App URL (always reachable)
FUNC=<functionAppName>                                  # e.g. func-products-dev-j3xqdaliqzms4
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

### 2. Fill in the params file(s)

Replace the four JWT-related parameters with your Okta values in `infra/main.parameters.dev.json` and/or `infra/main.parameters.prod.json` (each environment can point at a different Okta authorization server/audience if you want):

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
  --name azfn-crud-bootstrap-dev \
  --template-file infra/main.bicep \
  --parameters infra/main.parameters.dev.json \
  --parameters databaseUrl='postgresql://...'
# (repeat with main.parameters.prod.json / --name azfn-crud-bootstrap-prod for prod)
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

Each environment's federated credential is bound to a GitHub Actions **environment** (`dev` or `prod`, set via the `githubEnvironment` param) so OIDC trust matches what GitHub presents when `environment: dev`/`prod` is set on the workflow job. The Bicep already supports `staging` as an allowed `environment` value — add a `main.parameters.staging.json` and a matching GitHub Environment to use it. To trust other callers, add another `federatedIdentityCredentials` resource in `resources.bicep` with a different `subject`:

- another environment: `repo:<owner>/<repo>:environment:staging`
- a branch (when the workflow job has no `environment:`): `repo:<owner>/<repo>:ref:refs/heads/develop`
- a pull request: `repo:<owner>/<repo>:pull_request`

The subject claim GitHub actually sends shows up in the failed `azure/login` log line under `subject claim - …`; matching that string is the fix for `AADSTS700213`.

## Tear-down

```bash
az group delete --name rg-products-dev  --yes --no-wait   # dev
az group delete --name rg-products-prod --yes --no-wait   # prod
```

This removes everything Bicep created in that environment. Your external Postgres database is untouched.

## Cost notes (rough, westus2, idle POC)

- Flex Consumption: pay-per-execution + ~$0.000016/GB-s memory. Idle = $0.
- Storage account (LRS, minimal data): < $1/mo.
- Log Analytics + App Insights: free tier covers ~5GB/mo ingest; expect < $1/mo at POC volume.
- APIM Consumption: $0 idle, ~$3.50 per million calls.
- Total floor: a few dollars/month at low traffic.

> APIM Consumption provisions in ~5-10 minutes on first deploy. Subsequent deploys are fast (just policy/operation updates). If you re-run the deployment and the APIM service hasn't fully provisioned yet, ARM will wait until it's ready.
