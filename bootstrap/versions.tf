# versions.tf
terraform {
  required_version = "~> 1.5" # pick a constraint, be ready to defend ~> vs >=
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}