output "web_bucket_name" {
  value = module.web.bucket_name
}

output "web_distribution_id" {
  value = module.web.distribution_id
}

output "web_url" {
  value = "https://${local.web_domain}"
}
