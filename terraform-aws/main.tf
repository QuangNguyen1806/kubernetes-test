# Real AWS lab stack (module composition):
#   module.billing  → SNS + AWS Budget
#   module.lambda   → Python Lambda (container image from ECR) + IAM + CloudWatch
#   S3 + DynamoDB (items table) + API Gateway HTTP API → Lambda
#   ECR             → FastAPI app image + Lambda image repositories

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

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

# --- ECR: FastAPI / K8s app image (scopes A/B/D/E) ---
resource "aws_ecr_repository" "app" {
  name                 = "${var.project_name}-app"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # lab only

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# --- ECR: Lambda container image (scopes B/C/E) ---
resource "aws_ecr_repository" "lambda" {
  name                 = "${var.project_name}-lambda"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # lab only

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "lambda" {
  repository = aws_ecr_repository.lambda.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}

# Lambda service principal may pull this image (same account).
resource "aws_ecr_repository_policy" "lambda" {
  repository = aws_ecr_repository.lambda.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowLambdaPull"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = [
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability",
      ]
    }]
  })
}

# Resolve pushed image by tag → digest so Terraform detects new pushes of :latest
data "aws_ecr_image" "lambda" {
  repository_name = aws_ecr_repository.lambda.name
  image_tag       = var.lambda_image_tag

  depends_on = [aws_ecr_repository.lambda]
}

# --- DynamoDB items table ---
resource "aws_dynamodb_table" "items" {
  name         = "${var.project_name}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }
}

# --- Lambda (container image from ECR) ---
module "lambda" {
  source = "./modules/lambda"

  function_name       = "${var.project_name}-fn"
  role_name           = "${var.project_name}-lambda-role"
  policy_name         = "${var.project_name}-lambda-policy"
  image_uri           = "${aws_ecr_repository.lambda.repository_url}@${data.aws_ecr_image.lambda.image_digest}"
  s3_bucket_arns      = [aws_s3_bucket.demo.arn]
  dynamodb_table_arns = [aws_dynamodb_table.items.arn]

  environment = {
    BUCKET_NAME    = aws_s3_bucket.demo.bucket
    DYNAMODB_TABLE = aws_dynamodb_table.items.name
  }

  depends_on = [aws_ecr_repository_policy.lambda]
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

# GET /  — legacy S3 demo
resource "aws_apigatewayv2_route" "default" {
  api_id    = aws_apigatewayv2_api.demo.id
  route_key = "GET /"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# POST /items  — create
resource "aws_apigatewayv2_route" "items_create" {
  api_id    = aws_apigatewayv2_api.demo.id
  route_key = "POST /items"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# GET /items  — list all
resource "aws_apigatewayv2_route" "items_list" {
  api_id    = aws_apigatewayv2_api.demo.id
  route_key = "GET /items"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# GET /items/{id}  — get one
resource "aws_apigatewayv2_route" "items_get" {
  api_id    = aws_apigatewayv2_api.demo.id
  route_key = "GET /items/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

# DELETE /items/{id}  — delete one
resource "aws_apigatewayv2_route" "items_delete" {
  api_id    = aws_apigatewayv2_api.demo.id
  route_key = "DELETE /items/{id}"
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
