variable "function_name" {
  description = "Lambda function name"
  type        = string
}

variable "role_name" {
  description = "IAM role name for the Lambda execution role"
  type        = string
}

variable "policy_name" {
  description = "IAM policy name attached to the Lambda role"
  type        = string
}

variable "image_uri" {
  description = "ECR image URI for the Lambda function (package_type=Image)"
  type        = string
}

variable "handler" {
  description = "Container image CMD override (file.function)"
  type        = string
  default     = "handler.handler"
}

variable "timeout" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 10
}

variable "environment" {
  description = "Environment variables for the Lambda function"
  type        = map(string)
  default     = {}
}

variable "s3_bucket_arns" {
  description = "S3 bucket ARNs the function may read/write objects in"
  type        = list(string)
  default     = []
}

variable "dynamodb_table_arns" {
  description = "DynamoDB table ARNs the function may perform CRUD on"
  type        = list(string)
  default     = []
}

variable "log_retention_in_days" {
  description = "CloudWatch log retention for Lambda logs"
  type        = number
  default     = 7
}
