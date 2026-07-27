# Application AWS resources
# -----------------------------------------------------------------------------
# Audit (app/main.py, requirements.txt, K8s env): this app uses Redis only.
# There is no boto3 / aws-sdk / S3 / SQS / DynamoDB / Secrets Manager usage.
#
# Do NOT add speculative aws_* resources here. When the application gains real
# AWS SDK calls, add matching resources in this root module (or a submodule)
# and wire outputs + .env.example to the exact env var names the code reads.
# -----------------------------------------------------------------------------

# Connectivity check only — creates nothing. Confirms the provider talks to
# LocalStack (sts) rather than failing open against real AWS.
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}
