output "state_bucket_name" {
  description = "S3 bucket holding Terraform state for every other config in this repo."
  value       = aws_s3_bucket.tfstate.id
}

output "lock_table_name" {
  description = "DynamoDB table used for state locking."
  value       = aws_dynamodb_table.tflock.name
}

output "aws_account_id" {
  value = data.aws_caller_identity.current.account_id
}
