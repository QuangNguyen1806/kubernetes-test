variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must look like a normal AWS region (e.g. us-east-1)."
  }
}

variable "project_name" {
  description = "Name prefix for resources"
  type        = string
  default     = "k8s-test-demo"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3–40 chars, lowercase letters/numbers/hyphens, and start/end with alphanumeric."
  }
}

variable "billing_email" {
  description = "Email for AWS billing alerts (confirm the SNS subscription after apply)"
  type        = string

  validation {
    condition     = can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.billing_email))
    error_message = "billing_email must be a valid email address (e.g. you@example.com)."
  }
}

variable "budget_limit_usd" {
  description = "Monthly AWS cost budget limit in USD"
  type        = number
  default     = 5

  validation {
    condition     = var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be greater than 0."
  }
}

variable "lambda_image_tag" {
  description = "ECR tag for the Lambda container image (push with ./scripts/ecr-push.sh first)"
  type        = string
  default     = "latest"
}
