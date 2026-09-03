# main.tf — bootstrap: the S3 bucket + DynamoDB table that hold state for
# everything else. Applied with local state, then migrated into itself.

# ---------------------------------------------------------------------------
# 6. Naming. S3 bucket names are globally unique across all of AWS, so the name
#    is composed rather than hardcoded. account_id is deterministic (unlike
#    random_id, it produces no diff on re-apply and needs no extra provider);
#    region is in there so the same account can bootstrap a second region.
# ---------------------------------------------------------------------------
data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  state_bucket_name = "tf-state-${data.aws_caller_identity.current.account_id}-${data.aws_region.current.name}"
  lock_table_name   = "tf-state-lock"
}

# ---------------------------------------------------------------------------
# 1. The bucket itself. prevent_destroy because this object holds the state for
#    every other stack — losing it means losing the record of what exists.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "state" {
  bucket = local.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

# ---------------------------------------------------------------------------
# 2. Versioning. The DR answer: a truncated or corrupted state write is
#    recoverable by pulling the previous object version of terraform.tfstate.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id

  versioning_configuration {
    status = "Enabled"
  }
}

# ---------------------------------------------------------------------------
# 3. Encryption at rest. SSE-S3 (AES256), not SSE-KMS, deliberately: KMS would
#    mean every plan/apply from every principal needs kms:Decrypt on the key,
#    and the key itself would be another bootstrap dependency to manage before
#    state exists. SSE-S3 has no key policy and no extra cost.
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ---------------------------------------------------------------------------
# 4. Public access block. All four, and they are two distinct pairs:
#      ACL pair    — block_public_acls rejects NEW public ACLs;
#                    ignore_public_acls neuters ones ALREADY set.
#      Policy pair — block_public_policy rejects a NEW public bucket policy;
#                    restrict_public_buckets limits an EXISTING public policy
#                    to AWS service principals and authorized users.
#    Each pair is "stop it happening" + "defuse what's already there".
# ---------------------------------------------------------------------------
resource "aws_s3_bucket_public_access_block" "state" {
  bucket = aws_s3_bucket.state.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------------------------------------------------------------------------
# 5. Lock table. hash_key names the partition key; the attribute block declares
#    that key's type — two separate declarations that must agree. LockID is not
#    a choice, it is what Terraform's S3 backend writes.
#    PAY_PER_REQUEST: a lock table sees a handful of writes per apply.
# ---------------------------------------------------------------------------
resource "aws_dynamodb_table" "state_lock" {
  name         = local.lock_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}
