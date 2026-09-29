# versions.tf
terraform {
  required_version = "~> 1.11" # use_lockfile needs 1.11+; < 2.0 guards against the next majornstraint, be ready to defend ~> vs >=
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}