output "web_bucket_name" {
  value = module.web.bucket_name
}

output "admin_bucket_name" {
  value = module.admin.bucket_name
}

output "web_distribution_id" {
  value = module.web.distribution_id
}

output "admin_distribution_id" {
  value = module.admin.distribution_id
}

output "web_url" {
  value = "https://${local.web_domain}"
}

output "admin_url" {
  value = "https://${local.admin_domain}"
}

output "logs_bucket_name" {
  value = aws_s3_bucket.logs.id
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}
