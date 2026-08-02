module "web" {
  source = "./modules/cloudfront_spa"

  name                       = "${local.name_prefix}-web"
  domain_names               = [local.web_domain, local.api_domain]
  alb_origin_domain_name     = aws_lb.this.dns_name
  origin_verify_header_value = random_password.alb_origin_verify.result
  cert_arn                   = local.cert_arn
  web_acl_arn                = aws_wafv2_web_acl.public.arn
  logs_bucket_domain_name    = aws_s3_bucket.logs.bucket_domain_name
  logs_prefix                = "cloudfront-web/"
  enable_noindex             = false

  tags = {
    Component = "web"
  }
}

module "admin" {
  source = "./modules/cloudfront_spa"

  name                    = "${local.name_prefix}-admin"
  domain_names            = [local.admin_domain]
  cert_arn                = local.cert_arn
  web_acl_arn             = aws_wafv2_web_acl.admin.arn
  logs_bucket_domain_name = aws_s3_bucket.logs.bucket_domain_name
  logs_prefix             = "cloudfront-admin/"
  enable_noindex          = true

  tags = {
    Component = "admin"
  }
}
