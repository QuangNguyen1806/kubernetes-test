# Terraform + LocalStack (this repository)

## Why this exists

A full audit of `app/`, `requirements.txt`, and Kubernetes env showed **no AWS SDK usage**.
Item storage is **Redis** (`REDIS_*`), not S3/DynamoDB/SQS.

This module still provides a **safe, reproducible LocalStack + Terraform workflow** so that
when AWS is introduced, resources are declared here instead of clicking in a console.

Today `terraform apply` only reads LocalStack STS (`aws_caller_identity` / `aws_region`) and
manages **zero** `aws_*` resources (`managed_aws_resources = []`).

## Prerequisites

- Docker Desktop (healthy daemon + enough free disk for the LocalStack image, ~2 GiB+)
- Terraform `>= 1.5` (`brew install hashicorp/tap/terraform`)
- Optional: AWS CLI v2 for `./scripts/tf-localstack.sh verify`

## Quick start

```bash
cd "/Users/mac/Kubernetes Test"

./scripts/localstack-up.sh
./scripts/tf-localstack.sh init
./scripts/tf-localstack.sh apply
./scripts/tf-localstack.sh verify

# Idempotent re-apply
./scripts/tf-localstack.sh apply

# Tear down Terraform-managed resources (none today) then LocalStack
./scripts/tf-localstack.sh destroy
./scripts/localstack-down.sh
# wipe LocalStack volume: ./scripts/localstack-down.sh --volumes
```

## Safety

- Provider `endpoints` are hard-wired to `var.localstack_endpoint` (default `http://localhost:4566`).
- Variable validation rejects non-LocalStack hostnames.
- `allowed_account_ids = ["000000000000"]` (LocalStack default).
- Scripts unset `AWS_PROFILE` and set dummy `test`/`test` keys + `AWS_EC2_METADATA_DISABLED=true`.
- State is **local** under `terraform/` (gitignored) — no remote backend to real AWS.

## Adding a real AWS resource later

1. Add SDK usage and exact env var names in the application.
2. Add the matching `aws_*` resource in `main.tf` (or a new `.tf` file in this folder).
3. Export identifiers in `outputs.tf`.
4. Document env vars in `../.env.example` using those **exact** names.
5. Do not point this provider at real AWS; use a separate Terraform root for cloud.

## Endpoints

| Client location | Endpoint |
|-----------------|----------|
| Host (Terraform, AWS CLI) | `http://localhost:4566` |
| Compose sibling container | `http://localstack:4566` |
| Minikube pod → host LocalStack | `http://host.docker.internal:4566` |
