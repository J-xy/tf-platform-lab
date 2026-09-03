# outputs.tf — Stage 2 consumes these. The bucket name is composed at plan time
# from account ID + region, so it is not knowable until after apply; these are
# how you get the exact strings to paste into backend.tf.

output "state_bucket_name" {
  description = "S3 bucket holding remote state. Goes in backend.tf as `bucket`."
  value       = aws_s3_bucket.state.id
}

output "state_lock_table_name" {
  description = "DynamoDB lock table. Goes in backend.tf as `dynamodb_table`."
  value       = aws_dynamodb_table.state_lock.name
}

output "state_bucket_region" {
  description = "Region the bucket lives in. Goes in backend.tf as `region`."
  value       = data.aws_region.current.name
}
