module "web" {
  source = "./modules/cloudfront_spa"

  name                    = "${local.name_prefix}-web"
  domain_names            = [local.web_domain]
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

# --- API distribution: host-based, not path-based. beta-api.curry.space is
# its own dedicated distribution whose only origin is the ALB, so every path
# (not just /api/*) goes there -- unlike the earlier design where api_domain
# was just a second alias on the web distribution and only /api/* forwarded,
# leaving the app's own root-mounted routes (/healthz, /docs, /openapi.json)
# unreachable externally through that domain.

data "aws_cloudfront_cache_policy" "api_caching_disabled" {
  name = "Managed-CachingDisabled"
}

# NOT AllViewerExceptHostHeader: that policy replaces the Host header with
# the origin's own domain name (the ALB's raw *.elb.amazonaws.com DNS name).
# CloudFront then validates the ALB's presented certificate against that raw
# hostname -- but the ALB's listener cert only covers *.curry.space, so the
# TLS handshake fails and CloudFront returns 502 with "X-Cache: Error from
# cloudfront" (confirmed against a live beta apply). Forwarding the original
# Host header (the viewer's real hostname, which the cert does cover) is
# what AWS docs require for a custom origin whose cert doesn't match its own
# DNS name.
data "aws_cloudfront_origin_request_policy" "api_all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_distribution" "api" {
  enabled         = true
  is_ipv6_enabled = true
  aliases         = [local.api_domain]
  price_class     = "PriceClass_100"
  web_acl_id      = aws_wafv2_web_acl.public.arn
  http_version    = "http2and3"

  origin {
    domain_name = aws_lb.this.dns_name
    origin_id   = "alb-${local.name_prefix}-api"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Origin-Verify"
      value = random_password.alb_origin_verify.result
    }
  }

  default_cache_behavior {
    allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods           = ["GET", "HEAD"]
    target_origin_id         = "alb-${local.name_prefix}-api"
    viewer_protocol_policy   = "redirect-to-https"
    cache_policy_id          = data.aws_cloudfront_cache_policy.api_caching_disabled.id
    origin_request_policy_id = data.aws_cloudfront_origin_request_policy.api_all_viewer.id
  }

  logging_config {
    bucket          = aws_s3_bucket.logs.bucket_domain_name
    prefix          = "cloudfront-api/"
    include_cookies = false
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = local.cert_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  tags = {
    Component = "api"
  }
}
