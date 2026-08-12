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
