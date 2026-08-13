# Real AWS lab (module layout + remote state)

Separate from LocalStack under [`../terraform/`](../terraform/).

## Structure

```text
terraform-aws/
  main.tf / variables.tf / outputs.tf
  backend.tf                 # S3 remote state (partial config)
  backend.hcl.example        # copy → backend.hcl after bootstrap
  terraform.tfvars.example   # copy → terraform.tfvars
  modules/
    lambda/                  # Python Lambda + IAM + CloudWatch
    billing/                 # SNS email + AWS Budget
  bootstrap/                 # creates S3 bucket for remote Terraform state
```

## What it creates

| Component | Purpose |
|-----------|---------|
| `bootstrap/` | S3 bucket for **Terraform state** (versioned, encrypted, S3 lockfile) |
| `module.lambda` | Python 3.12 Lambda, IAM, CloudWatch log group |
| DynamoDB table | `k8s-test-demo-items` — stores items for the CRUD API |
| S3 demo bucket | Target for the legacy `GET /` hello.txt demo |
| API Gateway HTTP API | Routes `POST/GET/DELETE /items` and `GET /` to Lambda |
| `module.billing` | SNS + monthly cost budget |

```text
POST   /items        →  API Gateway  →  Lambda  →  DynamoDB (PutItem)
GET    /items        →  API Gateway  →  Lambda  →  DynamoDB (Scan)
GET    /items/{id}   →  API Gateway  →  Lambda  →  DynamoDB (GetItem)
DELETE /items/{id}   →  API Gateway  →  Lambda  →  DynamoDB (DeleteItem)
GET    /             →  API Gateway  →  Lambda  →  S3 (hello.txt)
                                           ↓
                                    CloudWatch Logs

AWS Budget → SNS → billing email

Terraform state → S3 (versioned + native lockfile)
```

### Lambda CRUD routes

| Method | Path | Action | DynamoDB operation |
|--------|------|--------|--------------------|
| `POST` | `/items` | Create item (auto UUID) | `PutItem` |
| `GET` | `/items` | List all items | `Scan` |
| `GET` | `/items/{id}` | Get one item | `GetItem` |
| `DELETE` | `/items/{id}` | Delete one item | `DeleteItem` |

**Input validation (POST /items):**

| Rule | Detail |
|------|--------|
| Body | Must be a JSON object |
| Allowed fields | `name` (required), `value` (optional) |
| Types | Both must be strings; `name` trimmed, non-empty |
| Length | `name` ≤ 128 chars, `value` ≤ 1024 chars |
| `id` | Server-assigned only — rejected if sent in body |
| Path `{id}` | Must be a valid UUID (GET/DELETE) |

Invalid input returns HTTP `400` with `{"error":"..."}`.

**Error handling:**

| Situation | HTTP | Response |
|-----------|------|----------|
| Bad input (validation) | `400` | `{"error":"..."}` |
| Item not found | `404` | `{"error":"Item '<uuid>' not found"}` |
| Unknown route | `404` | `{"error":"Route not found: ..."}` |
| DynamoDB / unexpected failure | `500` | `{"error":"DynamoDB operation failed"}` or `Internal server error` |

DynamoDB calls are wrapped in try/except; failures are logged and never crash the Lambda.

**Structured logging (Python `logging`):**

Every operation emits JSON log lines to CloudWatch, e.g.:

```json
{"operation": "create_item", "status": "created", "item_id": "...", "http_status": 201}
{"operation": "get_item", "status": "not_found", "item_id": "...", "http_status": 404}
{"operation": "create_item", "status": "error", "error_type": "ClientError", "error": "..."}
```

Log levels: `info` (request/start/success), `warning` (validation), `error` (DynamoDB failure).

**Unit tests (no AWS needed):**
```bash
source venv/bin/activate
pip install -r terraform-aws/modules/lambda/requirements-dev.txt
pytest terraform-aws/modules/lambda/tests -q
```

Tests cover: CRUD roundtrip, input validation, 404/500 error responses, and structured log output (pytest + moto).

**Quick demo:**
```bash
URL=$(terraform -chdir=terraform-aws output -raw api_url)

# Create
curl -X POST $URL/items -H 'Content-Type: application/json' -d '{"name":"foo","value":"bar"}'
# → {"id": "<uuid>", "name": "foo", "value": "bar"}

# Invalid (expect 400)
curl -sS -X POST $URL/items -H 'Content-Type: application/json' -d '{"name":""}'

# List
curl $URL/items
# → {"items": [...]}

# Get one
curl $URL/items/<uuid>

# Delete
curl -X DELETE $URL/items/<uuid>
# → {"deleted": "<uuid>"}
```

## Prerequisites

```bash
aws sts get-caller-identity   # real account (not 000000000000)
terraform >= 1.5
unset AWS_ENDPOINT_URL
```

## 1) Inject variables (tfvars)

```bash
cp terraform.tfvars.example terraform.tfvars
# edit billing_email to a real address
```

Terraform **auto-loads** `terraform.tfvars`. Other options:

```bash
./scripts/tf-aws.sh plan my-demo.tfvars          # -var-file
TF_VAR_billing_email=you@x.com ./scripts/tf-aws.sh plan
```

## 2) Custom variable validation

Root [`variables.tf`](variables.tf) rejects bad inputs before AWS calls:

| Variable | Rule |
|----------|------|
| `billing_email` | must look like an email |
| `budget_limit_usd` | must be `> 0` |
| `project_name` | 3–40 chars, lowercase / digits / hyphens |
| `aws_region` | e.g. `us-east-1` |

Demo a failure:

```bash
./scripts/tf-aws.sh demo-validation
```

## 3) Remote state (S3)

```bash
./scripts/tf-aws.sh bootstrap   # creates state bucket, writes backend.hcl
./scripts/tf-aws.sh init
./scripts/tf-aws.sh apply
```

Prove state is remote:

```bash
aws s3 ls s3://YOUR-STATE-BUCKET/terraform-aws/
# should show demo.tfstate
```

Locking uses S3 native lockfiles (`use_lockfile = true`) — no DynamoDB required.
## Test / destroy

```bash
./scripts/tf-aws.sh test
./scripts/tf-aws.sh destroy              # tear down Lambda/API/budget lab
./scripts/tf-aws.sh destroy-bootstrap    # last: delete state bucket
```

## Demo script for others (exact walkthrough)

```bash
cd "/Users/mac/Kubernetes Test"
unset AWS_ENDPOINT_URL

# A) Show validation rejects bad input
./scripts/tf-aws.sh demo-validation

# B) Show tfvars injection
cp terraform-aws/terraform.tfvars.example terraform-aws/terraform.tfvars
# edit billing_email, then:
./scripts/tf-aws.sh plan                 # values come from terraform.tfvars

# C) Bootstrap remote state, deploy app stack
./scripts/tf-aws.sh bootstrap
./scripts/tf-aws.sh apply

# D) Show state file in S3
grep bucket terraform-aws/backend.hcl
aws s3 ls "s3://$(grep bucket terraform-aws/backend.hcl | sed -E 's/.*"([^"]+)".*/\1/')/terraform-aws/"

# E) Hit the API + full checklist
./scripts/tf-aws.sh test
open "$(terraform -chdir=terraform-aws output -raw api_url)/"

# F) Cleanup (order matters)
./scripts/tf-aws.sh destroy
./scripts/tf-aws.sh destroy-bootstrap
```

After apply, **confirm the SNS subscription** in your inbox (required for billing emails).
