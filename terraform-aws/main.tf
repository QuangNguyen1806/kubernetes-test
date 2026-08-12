# Real AWS lab stack (module composition):
#   module.billing  → SNS + AWS Budget
#   module.lambda   → Python Lambda + IAM + CloudWatch
#   S3 + API Gateway HTTP API (GET /) → Lambda → S3

data "aws_caller_identity" "current" {}

# --- S3 ---
resource "aws_s3_bucket" "demo" {
  bucket_prefix = "${var.project_name}-"
  force_destroy = true # lab only — allows terraform destroy to empty the bucket
}

resource "aws_s3_bucket_public_access_block" "demo" {
  bucket = aws_s3_bucket.demo.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Lambda (reusable module) ---
module "lambda" {
  source = "./modules/lambda"

  function_name  = "${var.project_name}-fn"
  role_name      = "${var.project_name}-lambda-role"
  policy_name    = "${var.project_name}-lambda-policy"
  s3_bucket_arns = [aws_s3_bucket.demo.arn]

  environment = {
    BUCKET_NAME = aws_s3_bucket.demo.bucket
  }
}

# --- Billing alerts (SNS + AWS Budget) ---
module "billing" {
  source = "./modules/billing"

  billing_email    = var.billing_email
  budget_limit_usd = var.budget_limit_usd
  budget_name      = "${var.project_name}-monthly-budget"
  sns_topic_name   = "${var.project_name}-billing-alerts"
}

# --- API Gateway (HTTP API) → Lambda ---
resource "aws_apigatewayv2_api" "demo" {
  name          = "${var.project_name}-http"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.demo.id
  integration_type       = "AWS_PROXY"
  integration_uri        = module.lambda.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.demo.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.demo.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.demo.execution_arn}/*/*"
}
