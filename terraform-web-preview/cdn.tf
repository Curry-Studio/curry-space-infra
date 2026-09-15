module "web" {
  source = "../terraform/modules/cloudfront_spa"

  name                    = "${local.name_prefix}-web"
  domain_names            = [local.web_domain]
  cert_arn                = local.cert_arn
  web_acl_arn             = aws_wafv2_web_acl.public.arn
  logs_bucket_domain_name = aws_s3_bucket.logs.bucket_domain_name
  logs_prefix             = "cloudfront-web/"
  enable_noindex          = true # preview surface — keep it out of search results

  tags = {
    Component = "web"
    Preview   = var.preview_name
  }
}
