# Real AWS (uses your local `aws configure` credentials / default profile).
# Do NOT point this root at LocalStack — use ../terraform for that.

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project = var.project_name
      Managed = "terraform-aws"
    }
  }
}
