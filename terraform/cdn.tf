module "web" {
  source = "./modules/cloudfront_spa"

  name                    = "${local.name_prefix}-web"
  domain_name             = local.web_domain
  cert_arn                = local.cert_arn
  web_acl_arn             = aws_wafv2_web_acl.public.arn
  logs_bucket_domain_name = aws_s3_bucket.logs.bucket_domain_name
  logs_prefix             = "cloudfront-web/"
  enable_noindex          = false

  tags = {
    Component = "web"
  }
}

module "admin" {
  source = "./modules/cloudfront_spa"

  name                    = "${local.name_prefix}-admin"
  domain_name             = local.admin_domain
  cert_arn                = local.cert_arn
  web_acl_arn             = aws_wafv2_web_acl.admin.arn
  logs_bucket_domain_name = aws_s3_bucket.logs.bucket_domain_name
  logs_prefix             = "cloudfront-admin/"
  enable_noindex          = true

  tags = {
    Component = "admin"
  }
}
