#!/usr/bin/env bash
# Scope D: pull FastAPI image from ECR into Minikube so Flux apps run the ECR build.
#
# Default Flux overlays still use demo-api:latest + imagePullPolicy Never.
# This script pulls from ECR, retags as demo-api:latest inside Minikube's Docker,
# and restarts app deployments so pods pick up the new image.
#
# Prerequisites: Minikube running, ./scripts/ecr-push.sh app already done.
#
# Env:
#   MINIKUBE_PROFILE (default newprofile)
#   AWS_REGION, PROJECT_NAME, IMAGE_TAG
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROFILE="${MINIKUBE_PROFILE:-newprofile}"
REGION="${AWS_REGION:-us-east-1}"
PROJECT="${PROJECT_NAME:-k8s-test-demo}"
TAG="${IMAGE_TAG:-latest}"

die() { echo "ERROR: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

command -v aws >/dev/null || die "aws CLI required"
command -v docker >/dev/null || die "docker required"
command -v minikube >/dev/null || die "minikube required"
command -v kubectl >/dev/null || die "kubectl required"
[[ -z "${AWS_ENDPOINT_URL:-}" ]] || die "Unset AWS_ENDPOINT_URL"

minikube status -p "$PROFILE" >/dev/null 2>&1 || die "Minikube profile '$PROFILE' is not running"

ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"
REPO="${PROJECT}-app"
SRC="${REGISTRY}/${REPO}:${TAG}"

echo "==> Logging into ECR"
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$REGISTRY"

echo "==> Pulling $SRC (host Docker)"
docker pull --platform linux/amd64 "$SRC"

echo "==> Loading into Minikube ($PROFILE) as demo-api:latest"
# Prefer minikube image load (works across drivers)
docker tag "$SRC" "demo-api:latest"
minikube -p "$PROFILE" image load demo-api:latest

ok "Minikube has demo-api:latest (from ECR $SRC)"

echo "==> Restarting Flux app deployments to pick up image"
for ns_dep in flux-fastapi-ns/fastapi flux-api2-ns/api2 flux-api3-ns/api3; do
  ns="${ns_dep%%/*}"
  dep="${ns_dep##*/}"
  if kubectl --context "$PROFILE" -n "$ns" get deploy "$dep" >/dev/null 2>&1; then
    kubectl --context "$PROFILE" -n "$ns" rollout restart "deploy/$dep"
    ok "restarted $ns/$dep"
  else
    echo "SKIP: $ns/$dep not found (bootstrap Flux first)"
  fi
done

echo ""
echo "Verify:"
echo "  minikube -p $PROFILE image ls | grep demo-api"
echo "  kubectl --context $PROFILE -n flux-fastapi-ns get pods"
echo "  aws ecr list-images --repository-name $REPO"
