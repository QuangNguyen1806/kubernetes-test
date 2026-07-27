variable "aws_region" {
  description = "AWS region presented to LocalStack (does not contact real AWS)."
  type        = string
  default     = "us-east-1"
}

variable "aws_access_key_id" {
  description = "Dummy access key for LocalStack only."
  type        = string
  default     = "test"
  sensitive   = true
}

variable "aws_secret_access_key" {
  description = "Dummy secret key for LocalStack only."
  type        = string
  default     = "test"
  sensitive   = true
}

variable "localstack_endpoint" {
  description = "LocalStack edge endpoint (host-reachable)."
  type        = string
  default     = "http://localhost:4566"

  validation {
    condition     = can(regex("^https?://(localhost|127\\.0\\.0\\.1|localstack)(:[0-9]+)?/?$", var.localstack_endpoint))
    error_message = "localstack_endpoint must point at LocalStack (localhost, 127.0.0.1, or localstack), never a real AWS endpoint."
  }
}

variable "localstack_account_id" {
  description = "Expected LocalStack account id (Community default is 000000000000)."
  type        = string
  default     = "000000000000"
}

variable "project_name" {
  description = "Project tag / naming prefix for future aws_* resources."
  type        = string
  default     = "kubernetes-test"
}
