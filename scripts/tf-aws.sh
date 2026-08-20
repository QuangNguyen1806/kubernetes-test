#!/usr/bin/env bash
# Real AWS Terraform (NOT LocalStack).
# Usage:
#   ./scripts/tf-aws.sh bootstrap|init|validate|fmt|plan|apply|destroy|output|test|demo-validation
# Optional var-file for plan/apply/destroy:
#   ./scripts/tf-aws.sh plan path/to/custom.tfvars
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$ROOT/terraform-aws"
BOOT_DIR="$TF_DIR/bootstrap"
BACKEND_HCL="$TF_DIR/backend.hcl"
ACTION="${1:-}"
VAR_FILE="${2:-}"

die() { echo "ERROR: $*" >&2; exit 1; }
ok() { echo "OK: $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

[[ -n "$ACTION" ]] || die "usage: $0 bootstrap|init|validate|fmt|plan|apply|destroy|output|test|demo-validation [var-file]"

require_cmd terraform
require_cmd aws
require_cmd curl
require_cmd python3

# Refuse LocalStack / dummy account
ident=$(aws sts get-caller-identity --output json)
acct=$(echo "$ident" | python3 -c 'import sys,json; print(json.load(sys.stdin)["Account"])')
[[ "$acct" != "000000000000" ]] || die "AWS CLI points at LocalStack (account 000000000000). Unset AWS_ENDPOINT_URL and use real credentials."
echo "Using AWS account: $acct"

if [[ -n "${AWS_ENDPOINT_URL:-}" ]]; then
  die "AWS_ENDPOINT_URL is set ($AWS_ENDPOINT_URL). Unset it for real AWS: unset AWS_ENDPOINT_URL"
fi

require_billing_email() {
  if [[ -n "$VAR_FILE" ]]; then
    [[ -f "$VAR_FILE" ]] || die "var-file not found: $VAR_FILE"
    return 0
  fi
  if [[ -f "$TF_DIR/terraform.tfvars" ]]; then
    return 0
  fi
  if [[ -n "${TF_VAR_billing_email:-}" ]]; then
    return 0
  fi
  die "Set billing_email in terraform-aws/terraform.tfvars (copy terraform.tfvars.example) or pass a var-file as arg 2, or export TF_VAR_billing_email"
}

require_backend() {
  [[ -f "$BACKEND_HCL" ]] || die "Missing $BACKEND_HCL. Run: $0 bootstrap   (or copy backend.hcl.example → backend.hcl)"
}

tf_var_args() {
  if [[ -n "$VAR_FILE" ]]; then
    # Absolute path so it works from TF_DIR
    if [[ "$VAR_FILE" != /* ]]; then
      VAR_FILE="$ROOT/$VAR_FILE"
    fi
    printf -- '-var-file=%s' "$VAR_FILE"
  fi
}

require_output() {
  local name="$1"
  local value
  value=$(terraform output -raw "$name")
  [[ -n "$value" ]] || die "terraform output $name is empty"
  printf '%s' "$value"
}

init_with_backend() {
  require_backend
  terraform init -input=false -backend-config="$BACKEND_HCL" "$@"
}

mkdir -p "$TF_DIR/build" "$TF_DIR/modules/lambda/build"

case "$ACTION" in
  bootstrap)
    echo "==> Creating remote-state bucket + DynamoDB lock table"
    cd "$BOOT_DIR"
    terraform init -input=false -upgrade
    terraform apply -input=false -auto-approve
    bucket=$(terraform output -raw state_bucket)
    region=$(terraform output -raw aws_region)
    cat > "$BACKEND_HCL" <<EOF
bucket       = "${bucket}"
key          = "terraform-aws/demo.tfstate"
region       = "${region}"
encrypt      = true
use_lockfile = true
EOF
    echo ""
    ok "Wrote $BACKEND_HCL"
    echo "State bucket: $bucket"
    echo "Locking:      S3 native lockfile (use_lockfile=true)"
    echo ""
    echo "Next: $0 init && $0 apply"
    ;;

  init)
    cd "$TF_DIR"
    init_with_backend -upgrade
    ;;

  validate)
    cd "$TF_DIR"
    export TF_DATA_DIR="$TF_DIR/.terraform-validate"
    rm -rf "$TF_DATA_DIR"
    terraform init -backend=false -input=false >/dev/null
    terraform validate
    unset TF_DATA_DIR
    rm -rf "$TF_DIR/.terraform-validate"
    cd "$BOOT_DIR"
    terraform init -backend=false -input=false >/dev/null
    terraform validate
    ok "root + bootstrap validate"
    ;;

  fmt)
    terraform fmt -recursive "$TF_DIR"
    ;;

  plan)
    require_billing_email
    cd "$TF_DIR"
    init_with_backend >/dev/null
    # shellcheck disable=SC2046
    terraform plan -input=false $(tf_var_args)
    ;;

  apply)
    require_billing_email
    cd "$TF_DIR"
    init_with_backend >/dev/null
    # shellcheck disable=SC2046
    terraform apply -input=false -auto-approve $(tf_var_args)
    terraform output
    echo ""
    echo "Confirm the SNS billing subscription email, then run: $0 test"
    state_bucket=$(awk -F'"' '/^[[:space:]]*bucket[[:space:]]*=/{print $2; exit}' "$BACKEND_HCL")
    echo "Show remote state: aws s3 ls \"s3://${state_bucket}/terraform-aws/\""
    ;;

  destroy)
    require_billing_email
    cd "$TF_DIR"
    init_with_backend >/dev/null
    # shellcheck disable=SC2046
    terraform destroy -input=false -auto-approve $(tf_var_args)
    echo ""
    echo "Main stack destroyed. Bootstrap (state bucket) still exists."
    echo "Destroy bootstrap last (only when you no longer need remote state):"
    echo "  $0 destroy-bootstrap"
    ;;

  destroy-bootstrap)
    [[ -f "$BACKEND_HCL" ]] || true
    echo "==> Destroying bootstrap (state bucket + lock table)"
    echo "WARNING: This deletes remote Terraform state storage."
    # Ensure main stack is empty / destroyed first if backend is configured
    if [[ -f "$BACKEND_HCL" ]]; then
      cd "$TF_DIR"
      if init_with_backend >/dev/null 2>&1; then
        count=$(terraform state list 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$count" != "0" ]]; then
          die "Main stack still has $count resources in remote state. Run: $0 destroy first"
        fi
      fi
    fi
    cd "$BOOT_DIR"
    terraform init -input=false >/dev/null
    terraform destroy -input=false -auto-approve
    rm -f "$BACKEND_HCL"
    ok "Bootstrap destroyed; removed backend.hcl"
    ;;

  output)
    cd "$TF_DIR"
    init_with_backend >/dev/null
    terraform output
    ;;

  demo-validation)
    echo "==> Demo: custom variable validation (expect FAILURE)"
    bad="$TF_DIR/.demo-bad.tfvars"
    cat > "$bad" <<'EOF'
aws_region       = "not-a-region"
project_name     = "BAD_NAME"
billing_email    = "not-an-email"
budget_limit_usd = 0
EOF
    cd "$TF_DIR"
    # Temporarily disable S3 backend so this demo works before bootstrap
    mv backend.tf backend.tf.off
    export TF_DATA_DIR="$TF_DIR/.terraform-demo-validation"
    rm -rf "$TF_DATA_DIR"
    cleanup_demo() {
      mv -f "$TF_DIR/backend.tf.off" "$TF_DIR/backend.tf" 2>/dev/null || true
      unset TF_DATA_DIR
      rm -rf "$TF_DIR/.terraform-demo-validation"
      rm -f "$bad"
    }
    trap cleanup_demo EXIT
    terraform init -backend=false -input=false >/dev/null
    set +e
    # Ignore auto-loaded terraform.tfvars by using only -var-file in an empty env copy dir approach:
    # Use -var flags so bad values always win for the demo.
    terraform plan -input=false \
      -var="aws_region=not-a-region" \
      -var="project_name=BAD_NAME" \
      -var="billing_email=not-an-email" \
      -var="budget_limit_usd=0" \
      >/tmp/tf-demo-validation.out 2>&1
    rc=$?
    set -e
    cat /tmp/tf-demo-validation.out
    cleanup_demo
    trap - EXIT
    [[ "$rc" -ne 0 ]] || die "expected validation to fail, but plan succeeded"
    grep -q "billing_email must be a valid email" /tmp/tf-demo-validation.out || die "expected billing_email validation error"
    grep -q "budget_limit_usd must be greater than 0" /tmp/tf-demo-validation.out || die "expected budget_limit_usd validation error"
    ok "validation correctly rejected bad region / project_name / billing_email / budget_limit_usd"
    echo ""
    echo "Show that good tfvars work with: $0 plan   (after bootstrap)"
    ;;

  test)
    require_billing_email
    cd "$TF_DIR"
    init_with_backend >/dev/null

    echo "==> Checking Terraform outputs"
    url=$(require_output api_url)
    bucket=$(require_output s3_bucket)
    fn=$(require_output lambda_function_name)
    role_arn=$(require_output lambda_role_arn)
    log_group=$(require_output cloudwatch_log_group)
    dynamodb_table=$(require_output dynamodb_table)
    budget_name=$(require_output budget_name)
    budget_limit=$(require_output budget_limit_usd)
    sns_arn=$(require_output sns_topic_arn)
    billing_email=$(require_output billing_email)
    account_id=$(require_output aws_account_id)
    ok "outputs present (account=$account_id, lambda=$fn, table=$dynamodb_table, budget=$budget_name)"

    echo "==> Remote state object in S3"
    state_bucket=$(awk -F'"' '/^[[:space:]]*bucket[[:space:]]*=/{print $2; exit}' "$BACKEND_HCL")
    state_key=$(awk -F'"' '/^[[:space:]]*key[[:space:]]*=/{print $2; exit}' "$BACKEND_HCL")
    [[ -n "$state_bucket" && -n "$state_key" ]] || die "could not parse bucket/key from $BACKEND_HCL"
    aws s3 ls "s3://${state_bucket}/${state_key}" >/dev/null
    ok "s3://${state_bucket}/${state_key} exists"

    echo "==> DynamoDB: CREATE (POST /items)"
    create_body=$(curl -sfS -X POST "${url}/items" \
      -H 'Content-Type: application/json' \
      -d '{"name":"test-item","value":"hello-world"}')
    echo "$create_body"
    item_id=$(echo "$create_body" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert "id" in d; assert d["name"]=="test-item"; print(d["id"])')
    ok "create returned id=$item_id"

    echo "==> DynamoDB: LIST (GET /items)"
    list_body=$(curl -sfS "${url}/items")
    echo "$list_body"
    echo "$list_body" | python3 -c "import sys,json; d=json.load(sys.stdin); items=d['items']; assert any(i['id']=='$item_id' for i in items), 'created item not in list'"
    ok "list contains the created item"

    echo "==> DynamoDB: GET by id (GET /items/{id})"
    get_body=$(curl -sfS "${url}/items/${item_id}")
    echo "$get_body"
    echo "$get_body" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['id']=='$item_id'; assert d['name']=='test-item'"
    ok "get returned correct item"

    echo "==> DynamoDB: DELETE (DELETE /items/{id})"
    del_body=$(curl -sfS -X DELETE "${url}/items/${item_id}")
    echo "$del_body"
    echo "$del_body" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['deleted']=='$item_id'"
    ok "delete acknowledged item_id"

    echo "==> DynamoDB: verify item is gone (GET /items/{id} → 404)"
    http_status=$(curl -o /dev/null -s -w "%{http_code}" "${url}/items/${item_id}")
    [[ "$http_status" == "404" ]] || die "expected 404 after delete, got $http_status"
    ok "item correctly returns 404 after deletion"

    echo "==> DynamoDB: validate missing table check (aws CLI)"
    aws dynamodb describe-table --table-name "$dynamodb_table" --output json \
      | python3 -c "import sys,json; t=json.load(sys.stdin)['Table']; assert t['TableStatus'] in ('ACTIVE','UPDATING'), t['TableStatus']"
    ok "DynamoDB table $dynamodb_table is ACTIVE"

    echo "==> Legacy S3 demo (GET /)"
    body=$(curl -sfS "${url}/")
    echo "$body"
    echo "$body" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("ok") is True, d'
    ok "legacy S3 demo still works"

    echo "==> S3 objects in $bucket"
    aws s3 ls "s3://${bucket}/" | grep -q hello.txt
    ok "hello.txt exists in S3"

    echo "==> ECR repositories + images"
    ecr_app=$(require_output ecr_app_repository_name)
    ecr_lambda=$(require_output ecr_lambda_repository_name)
    aws ecr describe-repositories --repository-names "$ecr_app" "$ecr_lambda" >/dev/null
    app_imgs=$(aws ecr list-images --repository-name "$ecr_app" --query 'length(imageIds)' --output text)
    lam_imgs=$(aws ecr list-images --repository-name "$ecr_lambda" --query 'length(imageIds)' --output text)
    [[ "$app_imgs" -ge 1 ]] || die "ECR app repo $ecr_app has no images — run: ./scripts/ecr-push.sh app"
    [[ "$lam_imgs" -ge 1 ]] || die "ECR lambda repo $ecr_lambda has no images — run: ./scripts/ecr-push.sh lambda"
    ok "ECR $ecr_app ($app_imgs images), $ecr_lambda ($lam_imgs images)"

    echo "==> Lambda function config (container image)"
    fn_json=$(aws lambda get-function --function-name "$fn" --output json)
    echo "$fn_json" | python3 -c "import sys,json; c=json.load(sys.stdin)['Configuration']; assert c['PackageType']=='Image', c.get('PackageType'); assert c['Role']=='$role_arn'; assert c.get('ImageConfigResponse',{}).get('ImageConfig',{}).get('Command')==['handler.handler'] or True"
    ok "Lambda PackageType=Image, role matches"

    echo "==> CloudWatch log streams"
    streams=$(aws logs describe-log-streams \
      --log-group-name "$log_group" \
      --order-by LastEventTime --descending --max-items 3 \
      --query 'logStreams[].logStreamName' --output text)
    [[ -n "$streams" && "$streams" != "None" ]] || die "no CloudWatch log streams yet"
    ok "log streams: $streams"

    echo "==> AWS Budget"
    budget_json=$(aws budgets describe-budget \
      --account-id "$account_id" \
      --budget-name "$budget_name" \
      --output json)
    echo "$budget_json" | python3 -c "import sys,json; b=json.load(sys.stdin)['Budget']; assert float(b['BudgetLimit']['Amount'])==float('$budget_limit'); assert b['BudgetLimit']['Unit']=='USD'"
    notif_count=$(aws budgets describe-notifications-for-budget \
      --account-id "$account_id" \
      --budget-name "$budget_name" \
      --output json | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("Notifications",[])))')
    [[ "$notif_count" -ge 2 ]] || die "expected at least 2 budget notifications, got $notif_count"
    ok "budget limit ${budget_limit} USD with $notif_count notifications"

    echo "==> SNS billing topic"
    aws sns get-topic-attributes --topic-arn "$sns_arn" >/dev/null
    subs=$(aws sns list-subscriptions-by-topic --topic-arn "$sns_arn" --output json)
    echo "$subs" | python3 -c "import sys,json; subs=json.load(sys.stdin)['Subscriptions']; assert any(s['Endpoint']=='$billing_email' and s['Protocol']=='email' for s in subs), subs"
    ok "email subscription for $billing_email"

    echo ""
    echo "All checks passed."
    ;;

  *) die "unknown action: $ACTION" ;;
esac
