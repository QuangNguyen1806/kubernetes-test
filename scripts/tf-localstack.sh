#!/usr/bin/env bash
# Terraform against LocalStack only (never real AWS).
# Usage:
#   ./scripts/tf-localstack.sh init|validate|fmt|plan|apply|destroy|output|verify
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform"
ACTION="${1:-}"

die() { echo "ERROR: $*" >&2; exit 1; }

[[ -n "$ACTION" ]] || die "usage: $0 init|validate|fmt|plan|apply|destroy|output|verify"

command -v terraform >/dev/null 2>&1 || die "Install Terraform (>= 1.5): brew install terraform"
command -v curl >/dev/null 2>&1 || die "curl is required."

# Hard guards: refuse real AWS endpoints / profiles for this workflow.
export AWS_ACCESS_KEY_ID="${AWS_ACCESS_KEY_ID:-test}"
export AWS_SECRET_ACCESS_KEY="${AWS_SECRET_ACCESS_KEY:-test}"
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
export AWS_EC2_METADATA_DISABLED=true
export AWS_ENDPOINT_URL="${AWS_ENDPOINT_URL:-http://localhost:4566}"
unset AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE || true

if [[ -n "${AWS_ENDPOINT_URL:-}" ]] && [[ "$AWS_ENDPOINT_URL" != *localhost* && "$AWS_ENDPOINT_URL" != *127.0.0.1* && "$AWS_ENDPOINT_URL" != *localstack* ]]; then
  die "Refusing AWS_ENDPOINT_URL=$AWS_ENDPOINT_URL (must be LocalStack)."
fi

ensure_localstack() {
  curl -sf http://localhost:4566/_localstack/health >/dev/null 2>&1 \
    || die "LocalStack not healthy. Run: ./scripts/localstack-up.sh"
}

cd "$TF_DIR"

case "$ACTION" in
  init)
    terraform init -upgrade
    ;;
  validate)
    terraform init -backend=false >/dev/null
    terraform validate
    ;;
  fmt)
    terraform fmt -recursive -check "$TF_DIR" || {
      echo "Formatting drift — run: terraform fmt -recursive $TF_DIR"
      exit 1
    }
    ;;
  plan)
    ensure_localstack
    terraform init -input=false >/dev/null
    terraform plan -input=false
    ;;
  apply)
    ensure_localstack
    terraform init -input=false >/dev/null
    terraform apply -input=false -auto-approve
    terraform output
    ;;
  destroy)
    ensure_localstack
    terraform init -input=false >/dev/null
    terraform destroy -input=false -auto-approve
    ;;
  output)
    terraform output
    ;;
  verify)
    ensure_localstack
    echo "==> LocalStack health"
    curl -s http://localhost:4566/_localstack/health
    echo
    echo "==> STS via LocalStack (dummy credentials)"
    if command -v aws >/dev/null 2>&1; then
      aws --endpoint-url=http://localhost:4566 sts get-caller-identity
    else
      echo "(aws CLI not installed — skipping CLI STS; Terraform data sources cover this on apply)"
    fi
    if [[ -d .terraform ]]; then
      echo "==> Terraform outputs"
      terraform output || true
    else
      echo "(run: $0 apply — to populate Terraform state/outputs)"
    fi
    ;;
  *)
    die "unknown action: $ACTION"
    ;;
esac
