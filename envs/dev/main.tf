terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  required_version = ">= 1.7"
}

module "baseline_vpc" {
  source = "git::https://github.com/J-xy/tf-platform-lab.git//modules/baseline-vpc?ref=v0.1.0"

  name_prefix = var.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count
  tags        = { environment = "dev" }
}