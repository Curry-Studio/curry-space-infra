data "aws_caller_identity" "current" {}

# S3 bucket names are globally unique across every AWS account, so the
# account ID is appended even though the naming convention (cs-<env>-<region>-<component>)
# reads as if it already were.
resource "aws_s3_bucket" "this" {
  bucket = "${var.name}-${data.aws_caller_identity.current.account_id}"
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket                  = aws_s3_bucket.this.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_cloudfront_origin_access_control" "this" {
  name                              = var.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

data "aws_iam_policy_document" "bucket_policy" {
  statement {
    sid       = "AllowCloudFrontOAC"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.this.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket_policy.json
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

# NOT AllViewerExceptHostHeader: that policy replaces the Host header with
# the origin's own domain name (the ALB's raw *.elb.amazonaws.com DNS
# name). CloudFront then validates the ALB's presented certificate against
# that raw hostname -- but the ALB's listener cert only covers *.curry.space,
# so the TLS handshake fails and CloudFront returns 502 with
# "X-Cache: Error from cloudfront" (confirmed against a live beta apply).
# Forwarding the original Host header (the viewer's real hostname, which the
# cert does cover) is what AWS docs require for a custom origin whose cert
# doesn't match its own DNS name.
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

resource "aws_cloudfront_response_headers_policy" "noindex" {
  count = var.enable_noindex ? 1 : 0
  name  = "${var.name}-noindex"

  custom_headers_config {
    items {
      header   = "X-Robots-Tag"
      value    = "noindex, nofollow"
      override = true
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  aliases             = var.domain_names
  price_class         = var.price_class
  web_acl_id          = var.web_acl_arn
  http_version        = "http2and3"
  tags                = var.tags

  origin {
    domain_name              = aws_s3_bucket.this.bucket_regional_domain_name
    origin_id                = "s3-${var.name}"
    origin_access_control_id = aws_cloudfront_origin_access_control.this.id
  }

  dynamic "origin" {
    for_each = var.alb_origin_domain_name == null ? [] : [1]
    content {
      domain_name = var.alb_origin_domain_name
      origin_id   = "alb-${var.name}"

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }

      custom_header {
        name  = "X-Origin-Verify"
        value = var.origin_verify_header_value
      }
    }
  }

  default_cache_behavior {
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    target_origin_id           = "s3-${var.name}"
    viewer_protocol_policy     = "redirect-to-https"
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.caching_optimized.id
    response_headers_policy_id = var.enable_noindex ? aws_cloudfront_response_headers_policy.noindex[0].id : null
  }

  dynamic "ordered_cache_behavior" {
    for_each = var.alb_origin_domain_name == null ? [] : [1]
    content {
      path_pattern             = "/api/*"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      target_origin_id         = "alb-${var.name}"
      viewer_protocol_policy   = "redirect-to-https"
      cache_policy_id          = data.aws_cloudfront_cache_policy.caching_disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer.id
    }
  }

  # SPA fallback: a client-side route with no matching S3 key comes back as
  # 403 (bucket policy denies listing) or 404, and both need to resolve to
  # index.html with a 200 so the router — not CloudFront — decides the page.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  logging_config {
    bucket          = var.logs_bucket_domain_name
    prefix          = var.logs_prefix
    include_cookies = false
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = var.cert_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}
