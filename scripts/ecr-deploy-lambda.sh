#!/usr/bin/env bash
# Publish Lambda Python container to ECR and deploy via Terraform (scope C + versioning).
#
# Usage:
#   ./scripts/ecr-deploy-lambda.sh              # tag = git short SHA
#   ./scripts/ecr-deploy-lambda.sh v1.2.3       # explicit version tag
#   ./scripts/ecr-deploy-lambda.sh latest       # mutable latest (dev only)
#
# Flow:
#   1. Build & push handler.py Docker image to ECR with IMAGE_TAG
#   2. terraform apply with lambda_image_tag=<tag> (resolves tag → digest)
#   3. Verify Lambda PackageType=Image and run a quick API smoke test
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo latest)}"

die() { echo "ERROR: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

[[ -z "${AWS_ENDPOINT_URL:-}" ]] || die "Unset AWS_ENDPOINT_URL for real AWS"

echo "==> Step 1: Push Lambda image to ECR (tag=$TAG)"
IMAGE_TAG="$TAG" "$ROOT/scripts/ecr-push.sh" lambda

echo ""
echo "==> Step 2: Terraform apply (lambda_image_tag=$TAG)"
export TF_VAR_lambda_image_tag="$TAG"
"$ROOT/scripts/tf-aws.sh" apply

echo ""
echo "==> Step 3: Verify deployed image"
FN="${PROJECT_NAME:-k8s-test-demo}-fn"
REGION="${AWS_REGION:-us-east-1}"
LAMBDA_REPO="${PROJECT_NAME:-k8s-test-demo}-lambda"

deployed=$(aws lambda get-function --function-name "$FN" --region "$REGION" --output json \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['Code'].get('ResolvedImageUri') or d['Code'].get('ImageUri',''))")
ecr_digest=$(aws ecr describe-images --repository-name "$LAMBDA_REPO" --region "$REGION" \
  --image-ids "imageTag=$TAG" --query 'imageDetails[0].imageDigest' --output text)

[[ -n "$deployed" && "$deployed" != "None" ]] || die "Lambda has no image URI"
[[ "$deployed" == *"$ecr_digest"* ]] || die "Lambda digest mismatch: deployed=$deployed ecr=$ecr_digest"
ok "Lambda running image $deployed (tag=$TAG)"

echo ""
echo "==> Step 4: API smoke test (POST + DELETE /items)"
url=$(cd "$ROOT/terraform-aws" && terraform output -raw api_url 2>/dev/null) || die "terraform output api_url failed"

create=$(curl -sfS -X POST "${url}/items" -H 'Content-Type: application/json' \
  -d "{\"name\":\"deploy-test-${TAG}\",\"value\":\"ecr-deploy\"}")
item_id=$(echo "$create" | python3 -c 'import sys,json; print(json.load(sys.stdin)["id"])')
curl -sfS -X DELETE "${url}/items/${item_id}" >/dev/null
ok "CRUD smoke test passed via $url"

echo ""
echo "Deployed Lambda version tag: $TAG"
echo "Re-run full suite: ./scripts/ecr-test.sh"
