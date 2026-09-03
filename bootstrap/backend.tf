# backend.tf — Stage 2. This block points at the bucket and table that main.tf
# created; it can only exist after a successful local-state apply.
#
# Both lock mechanisms are on during the deprecation window:
#   dynamodb_table -> the original lock: a LockID item written to the table
#   use_lockfile   -> S3-native lock: a <key>.tflock object beside the state
# Terraform takes BOTH. dynamodb_table emits a deprecation warning on 1.11+.

terraform {
  backend "s3" {
    bucket         = "tf-state-964291633585-us-east-1"
    key            = "bootstrap/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "tf-state-lock"
    use_lockfile   = true
  }
}
