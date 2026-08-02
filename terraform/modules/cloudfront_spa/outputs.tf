output "bucket_name" {
  value = aws_s3_bucket.this.id
}

output "distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "distribution_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "distribution_hosted_zone_id" {
  description = "CloudFront's fixed hosted zone ID, needed for the Route 53 alias record."
  value       = aws_cloudfront_distribution.this.hosted_zone_id
}
