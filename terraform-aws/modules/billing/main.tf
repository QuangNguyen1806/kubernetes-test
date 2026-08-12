resource "aws_sns_topic" "billing" {
  name = var.sns_topic_name
}

data "aws_iam_policy_document" "sns_budgets" {
  statement {
    sid    = "AllowBudgetsPublish"
    effect = "Allow"
    actions = [
      "SNS:Publish",
    ]
    principals {
      type        = "Service"
      identifiers = ["budgets.amazonaws.com"]
    }
    resources = [aws_sns_topic.billing.arn]
  }
}

resource "aws_sns_topic_policy" "billing" {
  arn    = aws_sns_topic.billing.arn
  policy = data.aws_iam_policy_document.sns_budgets.json
}

resource "aws_sns_topic_subscription" "billing_email" {
  topic_arn = aws_sns_topic.billing.arn
  protocol  = "email"
  endpoint  = var.billing_email
}

resource "aws_budgets_budget" "monthly" {
  name         = var.budget_name
  budget_type  = "COST"
  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.billing.arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.billing.arn]
  }
}
