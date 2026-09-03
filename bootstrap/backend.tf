# backend.tf — Stage 2. This block points at the bucket and table that main.tf
# created; it can only exist after a successful local-state apply.
#
# Locking is S3-native: use_lockfile writes a <key>.tflock object beside the
# state using a conditional PutObject, so a second operation is refused with
# HTTP 412 PreconditionFailed. The DynamoDB table existed to solve this before
# S3 supported conditional writes; dynamodb_table is deprecated on 1.11+ and
# has been dropped.

terraform {
  backend "s3" {
    bucket       = "tf-state-964291633585-us-east-1"
    key          = "bootstrap/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
