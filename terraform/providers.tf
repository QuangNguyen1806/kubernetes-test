# Force all AWS API traffic to LocalStack. Dummy credentials only.
# Do not set a real AWS_PROFILE / real keys when running this root module.

provider "aws" {
  region                      = var.aws_region
  access_key                  = var.aws_access_key_id
  secret_key                  = var.aws_secret_access_key
  token                       = ""
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  # Must be false so allowed_account_ids can resolve LocalStack's
  # 000000000000 via STS; skip=true yields an empty id and fails the allow-list.
  skip_requesting_account_id = false
  s3_use_path_style          = true

  # LocalStack default account; rejects accidental use of a real account id
  # if the endpoint were ever mis-pointed (defense in depth).
  allowed_account_ids = [var.localstack_account_id]

  endpoints {
    apigateway     = var.localstack_endpoint
    cloudformation = var.localstack_endpoint
    cloudwatch     = var.localstack_endpoint
    dynamodb       = var.localstack_endpoint
    ec2            = var.localstack_endpoint
    eks            = var.localstack_endpoint
    iam            = var.localstack_endpoint
    kinesis        = var.localstack_endpoint
    lambda         = var.localstack_endpoint
    logs           = var.localstack_endpoint
    redshift       = var.localstack_endpoint
    s3             = var.localstack_endpoint
    secretsmanager = var.localstack_endpoint
    ses            = var.localstack_endpoint
    sns            = var.localstack_endpoint
    sqs            = var.localstack_endpoint
    ssm            = var.localstack_endpoint
    stepfunctions  = var.localstack_endpoint
    sts            = var.localstack_endpoint
  }
}
