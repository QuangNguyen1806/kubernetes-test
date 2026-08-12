# Partial backend config — filled by ./scripts/tf-aws.sh bootstrap
# Real values go in backend.hcl (gitignored). Copy from backend.hcl.example.

terraform {
  backend "s3" {}
}
