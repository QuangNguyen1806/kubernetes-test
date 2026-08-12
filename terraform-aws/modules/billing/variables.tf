variable "billing_email" {
  description = "Email address for billing alert notifications (must confirm SNS subscription)"
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
}

variable "budget_name" {
  description = "AWS Budget name"
  type        = string
}

variable "sns_topic_name" {
  description = "SNS topic name for billing alerts"
  type        = string
}
