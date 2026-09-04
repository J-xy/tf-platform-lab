# backend.tf — third key in the same bucket. Stage 1's backend, Stage 2's proof
# that keys are independent; this is simply the next tenant.
terraform {
  backend "s3" {
    bucket       = "tf-state-964291633585-us-east-1"
    key          = "ci/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
