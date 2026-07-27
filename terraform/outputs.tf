output "localstack_endpoint" {
  description = "LocalStack edge URL for host tooling and future AWS SDK endpoint_url."
  value       = var.localstack_endpoint
}

output "aws_region" {
  description = "Region configured for LocalStack."
  value       = data.aws_region.current.name
}

output "aws_account_id" {
  description = "Account id reported by LocalStack STS (expect 000000000000)."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_caller_arn" {
  description = "Caller ARN from LocalStack STS (smoke-test output)."
  value       = data.aws_caller_identity.current.arn
}

output "managed_aws_resources" {
  description = "AWS resources managed by this module for the current app."
  value       = []
}

output "integration_notes" {
  description = "How this relates to the running FastAPI apps."
  value       = <<-EOT
    No AWS resources are provisioned: demo-api stores items in Redis
    (REDIS_HOST / REDIS_PASSWORD / REDIS_KEY), not in AWS.
    LocalStack + this Terraform root are ready for future aws_* resources.
    Host endpoint: ${var.localstack_endpoint}
    From Docker Compose siblings, use http://localstack:4566
    From Minikube pods to host LocalStack (Docker Desktop): http://host.docker.internal:4566
  EOT
}
