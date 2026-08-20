#!/usr/bin/env bash
# End-to-end local test against real AWS: ECR + Lambda container + CRUD API.
#
# Usage:
#   ./scripts/ecr-test.sh              # verify existing deployment
#   ./scripts/ecr-test.sh --push       # rebuild/push images first, then verify
#   ./scripts/ecr-test.sh --deploy     # push + terraform apply + verify (uses git SHA tag)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MODE="${1:-verify}"

die() { echo "ERROR: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }
section() { echo ""; echo "==> $*"; }

[[ -z "${AWS_ENDPOINT_URL:-}" ]] || die "Unset AWS_ENDPOINT_URL for real AWS"

case "$MODE" in
  --push)
    section "Build & push Python images to ECR"
    "$ROOT/scripts/ecr-push.sh"
    MODE=verify
    ;;
  --deploy)
    section "Full deploy: push Lambda + terraform apply"
    "$ROOT/scripts/ecr-deploy-lambda.sh"
    MODE=verify
    ;;
  verify|"") ;;
  *) die "usage: $0 [--push|--deploy]" ;;
esac

section "1. Explore ECR (repos, images, Lambda image URI)"
"$ROOT/scripts/ecr-explore.sh" | tail -20

section "2. ECR has images in both repositories"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-k8s-test-demo}"
for repo in "${PROJECT}-app" "${PROJECT}-lambda"; do
  count=$(aws ecr list-images --repository-name "$repo" --region "$REGION" \
    --query 'length(imageIds)' --output text)
  [[ "$count" -ge 1 ]] || die "$repo has no images — run: ./scripts/ecr-push.sh"
  ok "$repo: $count image(s)"
done

section "3. Lambda uses ECR container (not zip)"
FN="${PROJECT}-fn"
pkg=$(aws lambda get-function --function-name "$FN" --region "$REGION" --output json \
  | python3 -c "import sys,json; c=json.load(sys.stdin); print(c['Configuration']['PackageType']); print(c['Code'].get('ResolvedImageUri') or c['Code'].get('ImageUri',''), end='')")
package_type=$(echo "$pkg" | head -1)
image_uri=$(echo "$pkg" | tail -1)
[[ "$package_type" == "Image" ]] || die "Lambda PackageType=$package_type (expected Image)"
[[ "$image_uri" == *"${PROJECT}-lambda"* ]] || die "Lambda not using ECR lambda repo: $image_uri"
ok "PackageType=Image, URI=$image_uri"

section "4. Version management (tag → digest pinning)"
tag="${TF_VAR_lambda_image_tag:-latest}"
if [[ -f "$ROOT/terraform-aws/terraform.tfvars" ]]; then
  tf_tag=$(grep -E '^lambda_image_tag' "$ROOT/terraform-aws/terraform.tfvars" 2>/dev/null \
    | sed -E 's/.*=\s*"([^"]+)".*/\1/' || true)
  [[ -n "$tf_tag" ]] && tag="$tf_tag"
fi
ecr_digest=$(aws ecr describe-images --repository-name "${PROJECT}-lambda" --region "$REGION" \
  --image-ids "imageTag=$tag" --query 'imageDetails[0].imageDigest' --output text 2>/dev/null || echo "")
[[ -n "$ecr_digest" && "$ecr_digest" != "None" ]] || die "ECR tag '$tag' not found"
[[ "$image_uri" == *"${ecr_digest#sha256:}"* || "$image_uri" == *"$ecr_digest"* ]] \
  || echo "NOTE: Lambda digest may differ if apply pending for tag=$tag (run ecr-deploy-lambda.sh)"
ok "ECR tag '$tag' → $ecr_digest"

section "5. Live CRUD against real AWS API (curl from laptop)"
cd "$ROOT/terraform-aws"
terraform init -input=false -backend-config="$ROOT/terraform-aws/backend.hcl" >/dev/null 2>&1 || true
url=$(terraform output -raw api_url 2>/dev/null) || die "terraform output api_url failed — run tf-aws.sh apply"

create=$(curl -sfS -X POST "${url}/items" -H 'Content-Type: application/json' \
  -d '{"name":"ecr-local-test","value":"real-aws"}')
item_id=$(echo "$create" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["name"]=="ecr-local-test"; print(d["id"])')
ok "POST /items → id=$item_id"

curl -sfS "${url}/items" | python3 -c "import sys,json; assert any(i['id']=='$item_id' for i in json.load(sys.stdin)['items'])"
ok "GET /items lists created item"

curl -sfS "${url}/items/${item_id}" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['id']=='$item_id'"
ok "GET /items/{id} works"

curl -sfS -X DELETE "${url}/items/${item_id}" | python3 -c "import sys,json; assert json.load(sys.stdin)['deleted']"
status=$(curl -o /dev/null -s -w '%{http_code}' "${url}/items/${item_id}")
[[ "$status" == "404" ]] || die "expected 404 after delete, got $status"
ok "DELETE /items/{id} + 404 verify"

section "6. Unit tests (pytest + moto, no AWS charges)"
cd "$ROOT/terraform-aws/modules/lambda"
python3 -m pytest tests/ -q
ok "pytest passed"

echo ""
echo "All ECR + Lambda + local-real-AWS checks passed."
echo "API base URL: $url"
