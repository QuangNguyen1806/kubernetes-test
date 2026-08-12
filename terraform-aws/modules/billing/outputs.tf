output "sns_topic_arn" {
  description = "SNS topic ARN for billing alerts"
  value       = aws_sns_topic.billing.arn
}

output "budget_name" {
  description = "AWS Budget name"
  value       = aws_budgets_budget.monthly.name
}

output "budget_limit_usd" {
  description = "Configured monthly budget limit in USD"
  value       = var.budget_limit_usd
}
