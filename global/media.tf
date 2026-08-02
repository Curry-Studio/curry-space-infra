# Two buckets total — nonprod (beta and staging share this one) and prod.
# No further subdivision (decisions.md D-008). Bucket names don't need an
# account-id suffix for uniqueness the way the state bucket does, since
# "cs-nonprod-use1-media" and "cs-prod-use1-media" are specific enough
# that a collision with an unrelated AWS customer's bucket is vanishingly
# unlikely — but if `terraform apply` fails with BucketAlreadyExists,
# that's the reason, and appending the account ID is the fix.

resource "aws_s3_bucket" "media" {
  for_each = toset(["nonprod", "prod"])
  bucket   = "cs-${each.value}-use1-media"
}

resource "aws_s3_bucket_versioning" "media" {
  for_each = aws_s3_bucket.media
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  for_each = aws_s3_bucket.media
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  for_each                = aws_s3_bucket.media
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
