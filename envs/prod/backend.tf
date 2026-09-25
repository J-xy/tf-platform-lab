terraform {
  backend "s3" {
    bucket       = "tf-state-964291633585-us-east-1"
    key          = "envs/prod/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}