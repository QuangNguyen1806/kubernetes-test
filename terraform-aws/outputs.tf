output "aws_account_id" {
  description = "Your real AWS account id"
  value       = data.aws_caller_identity.current.account_id
}

output "s3_bucket" {
  description = "Demo S3 bucket name"
  value       = aws_s3_bucket.demo.bucket
}

output "lambda_function_name" {
  description = "Deployed Lambda function name"
  value       = module.lambda.function_name
}

output "lambda_role_arn" {
  description = "IAM role assumed by Lambda"
  value       = module.lambda.role_arn
}

output "cloudwatch_log_group" {
  description = "CloudWatch log group for Lambda"
  value       = module.lambda.log_group_name
}

output "api_url" {
  description = "Base URL for the HTTP API (Lambda + DynamoDB CRUD)"
  value       = aws_apigatewayv2_api.demo.api_endpoint
}

output "dynamodb_table" {
  description = "DynamoDB items table name"
  value       = aws_dynamodb_table.items.name
}

output "ecr_app_repository_name" {
  description = "ECR repo for FastAPI / Minikube (demo-api) image"
  value       = aws_ecr_repository.app.name
}

output "ecr_app_repository_url" {
  description = "Docker URL for FastAPI image"
  value       = aws_ecr_repository.app.repository_url
}

output "ecr_lambda_repository_name" {
  description = "ECR repo for Lambda container image"
  value       = aws_ecr_repository.lambda.name
}

output "ecr_lambda_repository_url" {
  description = "Docker URL for Lambda image"
  value       = aws_ecr_repository.lambda.repository_url
}

output "lambda_image_uri" {
  description = "Digest-pinned Lambda image URI used by the function"
  value       = "${aws_ecr_repository.lambda.repository_url}@${data.aws_ecr_image.lambda.image_digest}"
}

# Back-compat aliases
output "ecr_repository_name" {
  description = "Alias for ecr_app_repository_name"
  value       = aws_ecr_repository.app.name
}

output "ecr_repository_url" {
  description = "Alias for ecr_app_repository_url"
  value       = aws_ecr_repository.app.repository_url
}

output "budget_name" {
  description = "AWS Budget name for cost alerts"
  value       = module.billing.budget_name
}

output "budget_limit_usd" {
  description = "Configured monthly budget limit in USD"
  value       = module.billing.budget_limit_usd
}

output "sns_topic_arn" {
  description = "SNS topic ARN for billing alerts"
  value       = module.billing.sns_topic_arn
}

output "billing_email" {
  description = "Email subscribed to billing alerts"
  value       = var.billing_email
}
