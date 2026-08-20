#!/usr/bin/env bash
# Explore Amazon ECR for this project (CLI equivalent of the AWS Console ECR pages).
#
# Usage:
#   ./scripts/ecr-explore.sh
#
# Env:
#   AWS_REGION   (default us-east-1)
#   PROJECT_NAME (default k8s-test-demo)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-k8s-test-demo}"
APP_REPO="${PROJECT}-app"
LAMBDA_REPO="${PROJECT}-lambda"
FN_NAME="${PROJECT}-fn"

die() { echo "ERROR: $*" >&2; exit 1; }
section() { echo ""; echo "=== $* ==="; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }
require_cmd aws
require_cmd python3

[[ -z "${AWS_ENDPOINT_URL:-}" ]] || die "Unset AWS_ENDPOINT_URL for real ECR"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT" != "000000000000" ]] || die "AWS CLI points at LocalStack"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

section "Account & registry"
echo "Account:  $ACCOUNT"
echo "Region:   $REGION"
echo "Registry: $REGISTRY"
echo "Repos:    $APP_REPO (FastAPI), $LAMBDA_REPO (Lambda handler)"

section "Repositories (describe-repositories)"
aws ecr describe-repositories \
  --repository-names "$APP_REPO" "$LAMBDA_REPO" \
  --region "$REGION" \
  --query 'repositories[].{Name:repositoryName,URI:repositoryUri,Scan:imageScanningConfiguration.scanOnPush,Mutability:imageTagMutability,Created:createdAt}' \
  --output table

describe_repo_detail() {
  local name="$1"
  section "Repository detail: $name"
  aws ecr describe-repositories --repository-names "$name" --region "$REGION" --output json \
    | python3 -c "
import sys, json
r = json.load(sys.stdin)['repositories'][0]
print('URI:', r['repositoryUri'])
print('ARN:', r['repositoryArn'])
print('Scan on push:', r.get('imageScanningConfiguration', {}).get('scanOnPush'))
print('Tag mutability:', r.get('imageTagMutability'))
"
  echo ""
  echo "Lifecycle policy:"
  aws ecr get-lifecycle-policy --repository-name "$name" --region "$REGION" \
    --query 'lifecyclePolicyText' --output text 2>/dev/null || echo "  (none — Terraform may add keep-last-10)"
  echo ""
  echo "Repository policy (Lambda pull, etc.):"
  aws ecr get-repository-policy --repository-name "$name" --region "$REGION" \
    --query 'policyText' --output text 2>/dev/null | python3 -m json.tool 2>/dev/null || echo "  (none)"
}

list_images() {
  local name="$1"
  section "Images in $name"
  aws ecr describe-images --repository-name "$name" --region "$REGION" --output json \
    | python3 -c "
import sys, json
details = json.load(sys.stdin).get('imageDetails', [])
details.sort(key=lambda d: d.get('imagePushedAt', ''), reverse=True)
if not details:
    print('  (no images — run: ./scripts/ecr-push.sh)')
    sys.exit(0)
for d in details[:10]:
    tags = d.get('imageTags') or ['<untagged>']
    digest = d.get('imageDigest', '')[:19] + '...'
    pushed = d.get('imagePushedAt', '?')
    size_mb = (d.get('imageSizeInBytes') or 0) / 1024 / 1024
    print(f\"  {', '.join(tags):20}  {digest}  {size_mb:.1f} MiB  pushed {pushed}\")
if len(details) > 10:
    print(f'  ... and {len(details) - 10} more')
"
}

describe_repo_detail "$APP_REPO"
list_images "$APP_REPO"

describe_repo_detail "$LAMBDA_REPO"
list_images "$LAMBDA_REPO"

section "Lambda function (container from ECR, not zip)"
if aws lambda get-function --function-name "$FN_NAME" --region "$REGION" >/dev/null 2>&1; then
  aws lambda get-function --function-name "$FN_NAME" --region "$REGION" --output json \
    | python3 -c "
import sys, json
data = json.load(sys.stdin)
c = data['Configuration']
code = data['Code']
print('Function:     ', c['FunctionName'])
print('Package type: ', c['PackageType'])
print('Runtime:      ', c.get('Runtime') or '(container — no zip runtime)')
print('Image URI:    ', code.get('ImageUri') or code.get('ResolvedImageUri'))
print('Last modified:', c['LastModified'])
cmd = (c.get('ImageConfigResponse') or {}).get('ImageConfig', {}).get('Command')
if cmd:
    print('Handler cmd:  ', cmd)
"
else
  echo "  Lambda $FN_NAME not found — run ./scripts/tf-aws.sh apply after pushing images"
fi

section "Version pinning (Terraform → digest)"
if [[ -f "$ROOT/terraform-aws/terraform.tfvars" ]]; then
  tag=$(grep -E '^lambda_image_tag' "$ROOT/terraform-aws/terraform.tfvars" 2>/dev/null | sed 's/.*=\s*"\?\([^"]*\)"\?.*/\1/' || echo "latest")
else
  tag="latest"
fi
echo "Terraform lambda_image_tag (from tfvars or default): $tag"
aws ecr describe-images --repository-name "$LAMBDA_REPO" --region "$REGION" \
  --image-ids "imageTag=$tag" --output json 2>/dev/null \
  | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)['imageDetails'][0]
    print('ECR digest for tag \"$tag\":', d['imageDigest'])
except Exception:
    print('Tag \"$tag\" not found in ECR — push with: IMAGE_TAG=$tag ./scripts/ecr-push.sh lambda')
" || true

section "How Python code becomes an ECR image"
cat <<'EOF'
  handler.py  →  Dockerfile (COPY into AWS Lambda Python 3.12 base)
              →  docker build --platform linux/amd64
              →  docker push → ECR (k8s-test-demo-lambda:tag)
              →  terraform apply resolves tag → digest → Lambda PackageType=Image

  Publish:  ./scripts/ecr-push.sh lambda
  Deploy:   ./scripts/ecr-deploy-lambda.sh [tag]
  Version:  use IMAGE_TAG or git SHA; pin in Terraform via lambda_image_tag
EOF

echo ""
echo "Done. Run ./scripts/ecr-test.sh for live CRUD + ECR checks."
