terraform {
  required_version = "~> 1.11" # use_lockfile needs 1.11+; < 2.0 guards against the next major
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
