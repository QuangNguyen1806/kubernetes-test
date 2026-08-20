#!/usr/bin/env bash
# Build and push Docker images to Amazon ECR (scopes B + helper for C/D/E).
#
# Usage:
#   ./scripts/ecr-push.sh              # push FastAPI (app) + Lambda images
#   ./scripts/ecr-push.sh app          # FastAPI only
#   ./scripts/ecr-push.sh lambda       # Lambda only
#
# Env:
#   AWS_REGION   (default us-east-1)
#   PROJECT_NAME (default k8s-test-demo)
#   IMAGE_TAG    (default latest)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-k8s-test-demo}"
TAG="${IMAGE_TAG:-latest}"
TARGET="${1:-all}"

die() { echo "ERROR: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "Missing: $1"; }

require_cmd aws
require_cmd docker
require_cmd python3

[[ -z "${AWS_ENDPOINT_URL:-}" ]] || die "Unset AWS_ENDPOINT_URL for real ECR"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
[[ "$ACCOUNT" != "000000000000" ]] || die "AWS CLI points at LocalStack"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

ensure_repo() {
  local name="$1"
  if aws ecr describe-repositories --repository-names "$name" --region "$REGION" >/dev/null 2>&1; then
    ok "ECR repo exists: $name"
  else
    echo "==> Creating ECR repository $name"
    aws ecr create-repository \
      --repository-name "$name" \
      --region "$REGION" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability MUTABLE >/dev/null
    ok "created $name"
  fi
}

ecr_login() {
  echo "==> Logging into ECR $REGISTRY"
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$REGISTRY"
}

# Allow Lambda service to pull images from this repo (same account).
ensure_lambda_pull_policy() {
  local name="$1"
  local policy
  policy=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AllowLambdaPull",
      "Effect": "Allow",
      "Principal": { "Service": "lambda.amazonaws.com" },
      "Action": [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ]
    }
  ]
}
EOF
)
  aws ecr set-repository-policy \
    --repository-name "$name" \
    --region "$REGION" \
    --policy-text "$policy" >/dev/null
  ok "Lambda pull policy on $name"
}

push_app() {
  local name="${PROJECT}-app"
  local uri="${REGISTRY}/${name}:${TAG}"
  ensure_repo "$name"
  echo "==> Building FastAPI image (linux/amd64, Docker V2 manifest) → $uri"
  # Lambda/ECR consumers need Docker media types (not OCI index/attestations).
  docker build --platform linux/amd64 -t "$uri" -f "$ROOT/Dockerfile" "$ROOT"
  docker push "$uri"
  ok "pushed $uri"
  aws ecr describe-images --repository-name "$name" --region "$REGION" \
    --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags' --output text
}

push_lambda() {
  local name="${PROJECT}-lambda"
  local uri="${REGISTRY}/${name}:${TAG}"
  ensure_repo "$name"
  ensure_lambda_pull_policy "$name"
  echo "==> Building Lambda image (linux/amd64, Docker V2 manifest) → $uri"
  docker build --platform linux/amd64 -t "$uri" \
    -f "$ROOT/terraform-aws/modules/lambda/Dockerfile" \
    "$ROOT/terraform-aws/modules/lambda/src"
  docker push "$uri"
  ok "pushed $uri"
  aws ecr describe-images --repository-name "$name" --region "$REGION" \
    --query 'sort_by(imageDetails,& imagePushedAt)[-1].imageTags' --output text
}

ecr_login

case "$TARGET" in
  all)
    push_app
    push_lambda
    ;;
  app) push_app ;;
  lambda) push_lambda ;;
  *) die "usage: $0 [all|app|lambda]" ;;
esac

echo ""
echo "App image:    ${REGISTRY}/${PROJECT}-app:${TAG}"
echo "Lambda image: ${REGISTRY}/${PROJECT}-lambda:${TAG}"
echo ""
echo "Next:"
echo "  ./scripts/tf-aws.sh apply   # point Lambda at ECR image"
echo "  ./scripts/ecr-minikube-sync.sh   # load FastAPI image into Minikube"
