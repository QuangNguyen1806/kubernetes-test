# One-time bootstrap for Terraform remote state.
# Creates an S3 bucket (versioned, encrypted, private) for state + S3 native locking.
# Keep this stack's OWN state local (chicken-and-egg).
#
# Usage:
#   ./scripts/tf-aws.sh bootstrap
# then ../backend.hcl is written automatically.

terraform {
  required_version = ">= 1.5.0, < 2.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.82"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project_name
      Managed = "terraform-aws-bootstrap"
      Purpose = "terraform-remote-state"
    }
  }
}

variable "aws_region" {
  description = "AWS region for the state bucket and lock table"
  type        = string
  default     = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}-[a-z]+-[0-9]+$", var.aws_region))
    error_message = "aws_region must look like a normal AWS region (e.g. us-east-1)."
  }
}

variable "project_name" {
  description = "Name prefix"
  type        = string
  default     = "k8s-test-demo"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,38}[a-z0-9]$", var.project_name))
    error_message = "project_name must be 3–40 chars, lowercase letters/numbers/hyphens."
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "state" {
  bucket_prefix = "${var.project_name}-tfstate-"
  force_destroy = true # lab only
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}

output "state_bucket" {
  description = "S3 bucket for terraform-aws remote state"
  value       = aws_s3_bucket.state.bucket
}

output "aws_region" {
  value = var.aws_region
}

output "backend_hcl" {
  description = "Paste into terraform-aws/backend.hcl"
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    key          = "terraform-aws/demo.tfstate"
    region       = "${var.aws_region}"
    encrypt      = true
    use_lockfile = true
  EOT
}
