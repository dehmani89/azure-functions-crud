# azure-functions-crud

A serverless CRUD API (Node.js Azure Functions v4 + PostgreSQL) for managing `products`.

There are two ways to run it:

| Goal | Where to look |
|---|---|
| **Run and test locally** with a Postgres on your machine | This README (sections 1–11 below) |
| **Deploy to Azure** (Flex Consumption + GitHub Actions OIDC) | [`infra/README.md`](infra/README.md) |

Either way, the application code lives in `src/functions/` and uses the shared `pg.Pool` in `src/db.js`. The infrastructure-as-code lives in `infra/` (Bicep); the CI/CD workflow lives in `.github/workflows/deploy.yml`.

---

## Local Development Guide

The rest of this document covers running the API on your laptop.

## 1. Prerequisites

Install the following before starting:

| Tool                          | Version          | Install                                                                 |
|-------------------------------|------------------|-------------------------------------------------------------------------|
| Node.js                       | 18 LTS or newer  | https://nodejs.org or `brew install node`                               |
| npm                           | bundled w/ Node  | —                                                                       |
| Azure Functions Core Tools    | v4               | `brew tap azure/functions && brew install azure-functions-core-tools@4` |
| PostgreSQL                    | 13+              | `brew install postgresql@16` (or run via Docker)                        |
| `psql` CLI                    | matches server   | Included with PostgreSQL                                                |
| curl or an HTTP client        | any              | Built-in / Postman / HTTPie                                             |

Verify your installs:

```bash
node --version
npm --version
func --version          # should report 4.x
psql --version
```

## 2. Clone & Install

```bash
git clone <your-fork-url>
cd backend/azure-functions-crud
npm install
```

## 3. Start PostgreSQL

### Option A — Local Homebrew install

```bash
brew services start postgresql@16
createdb productsDB
```

### Option B — Docker (recommended for a clean slate)

```bash
docker run --name products-pg \
  -e POSTGRES_USER=<YOUR_USERNAME_HERE> \
  -e POSTGRES_PASSWORD=<YOUR_PASSWORD_HERE> \
  -e POSTGRES_DB=productsDB \
  -p 5432:5432 \
  -d postgres:16
```

## 4. Initialize the Database

Run the schema + seed script (creates the `products` table and inserts 15 dental-equipment rows):

```bash
psql "postgresql://<YOUR_USERNAME_HERE>:<YOUR_PASSWORD_HERE>@localhost:5432/productsDB" -f sql/setup.sql
```

Verify the table:

```bash
psql "postgresql://<YOUR_USERNAME_HERE>:<YOUR_PASSWORD_HERE>@localhost:5432/productsDB" -c "SELECT COUNT(*) FROM products;"
```

## 5. Configure `local.settings.json`

This file is git-ignored. Create or update it at the repo root:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "",
    "FUNCTIONS_WORKER_RUNTIME": "node",
    "DATABASE_URL": "postgresql://<YOUR_USERNAME_HERE>:<YOUR_PASSWORD_HERE>@localhost:5432/productsDB"
  }
}
```

Notes:
- `DATABASE_URL` is consumed by `src/db.js` via `process.env`.
- SSL is automatically disabled when `NODE_ENV` is not `production`, so no extra config is needed for local Postgres.
- `AzureWebJobsStorage` can stay empty for HTTP-only triggers.

## 6. Run the Functions Host

```bash
npm start
# equivalent to: func start
```

You should see a banner like:

```
Functions:
  createProduct:    [POST]   http://localhost:7071/api/products
  deleteProduct:    [DELETE] http://localhost:7071/api/products/{id}
  getProductById:   [GET]    http://localhost:7071/api/products/{id}
  getProducts:      [GET]    http://localhost:7071/api/products
  updateProduct:    [PUT]    http://localhost:7071/api/products/{id}
  healthcheck:      [GET]    http://localhost:7071/api/healthcheck
```

Keep this terminal open; it streams logs from every invocation.

## 7. Test the Endpoints

Open a second terminal and exercise each route with `curl`.

### Health check

```bash
curl -i http://localhost:7071/api/healthcheck
# 200 {"status":"Service Up 2"}
```

### List all products

```bash
curl -s http://localhost:7071/api/products | jq
```

### Fetch by ID

```bash
curl -s http://localhost:7071/api/products/2 | jq
```

### Create a product

```bash
curl -s -X POST http://localhost:7071/api/products \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Apex Locator",
    "description": "Electronic root canal length measurement device",
    "price": 320.00
  }' | jq
# 201 with the created row
```

Validation: omitting `name` or `price` returns `400 Name and price are required`.

### Update a product

```bash
curl -s -X PUT http://localhost:7071/api/products/2 \
  -H "Content-Type: application/json" \
  -d '{
    "name": "X-Ray Machine (refurbished)",
    "description": "Digital panoramic X-ray system",
    "price": 12000.00
  }' | jq
```

Unknown id → `404 Product not found`.

### Delete a product

```bash
curl -i -X DELETE http://localhost:7071/api/products/3
# 200 {"message":"Product deleted successfully"}
```

## 8. Quick Smoke-Test Script

Paste this into a terminal to run the full CRUD path end-to-end:

```bash
BASE=http://localhost:7071/api

echo "→ healthcheck"; curl -s $BASE/healthcheck; echo

echo "→ create"; CREATED=$(curl -s -X POST $BASE/products \
  -H "Content-Type: application/json" \
  -d '{"name":"Test Widget","description":"smoke test","price":9.99}')
echo "$CREATED"
ID=$(echo "$CREATED" | jq -r .id)

echo "→ get by id"; curl -s $BASE/products/$ID; echo
echo "→ update";    curl -s -X PUT $BASE/products/$ID \
  -H "Content-Type: application/json" \
  -d '{"name":"Test Widget v2","description":"updated","price":19.99}'; echo
echo "→ delete";    curl -s -X DELETE $BASE/products/$ID; echo
```

## 9. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| `func: command not found` | Install Azure Functions Core Tools v4 (see Prerequisites). |
| `ECONNREFUSED 127.0.0.1:5432` | Postgres isn't running. Start it via `brew services` or `docker start products-pg`. |
| `error: password authentication failed` | `DATABASE_URL` user/password doesn't match Postgres. Re-check `local.settings.json`. |
| `relation "products" does not exist` | You haven't run `sql/setup.sql` against the right database. |
| `500 Internal server error` on every call | Check the `func start` terminal — `context.log.error` prints the exact pg error. |
| Port 7071 already in use | Another `func start` is running, or pass `--port 7072` to `func start`. |
| Changes to `function.js` not picked up | Restart `func start`; the v4 model loads handlers at startup. |

## 10. Reset the Database

If your data gets messy:

```bash
psql "postgresql://<YOUR_USERNAME_HERE>:<YOUR_PASSWORD_HERE>@localhost:5432/productsDB" \
  -c "DROP TABLE IF EXISTS products;"
psql "postgresql://<YOUR_USERNAME_HERE>:<YOUR_PASSWORD_HERE>@localhost:5432/productsDB" -f sql/setup.sql
```

## 11. Project Layout (for orientation)

```
azure-functions-crud/
├── .github/workflows/
│   └── deploy.yml                 # CI/CD: push to main → deploy to Azure via OIDC
├── infra/                         # Bicep IaC (see infra/README.md)
│   ├── main.bicep                 # Subscription-scope entry point
│   ├── resources.bicep            # RG-scope: Function App, storage, identity, etc.
│   ├── main.parameters.json       # Parameter values (databaseUrl is a placeholder)
│   └── README.md                  # Cloud deployment guide
├── sql/
│   └── setup.sql                  # Postgres schema + seed data
├── src/
│   ├── index.js                   # app.setup({ enableHttpStream: true })
│   ├── db.js                      # Shared pg.Pool
│   └── functions/
│       ├── healthcheck/function.js
│       └── products/
│           ├── createProduct/function.js   # POST   /products
│           ├── getProducts/function.js     # GET    /products
│           ├── getProductById/function.js  # GET    /products/{id}
│           ├── updateProduct/function.js   # PUT    /products/{id}
│           └── deleteProduct/function.js   # DELETE /products/{id}
├── host.json                      # Functions host config + App Insights sampling
├── local.settings.json            # Local env vars (git-ignored)
├── local.settings.json.example    # Template — copy to local.settings.json and fill in
├── package.json
└── .funcignore                    # Files excluded from the deploy package
```

## License

See [LICENSE](LICENSE).