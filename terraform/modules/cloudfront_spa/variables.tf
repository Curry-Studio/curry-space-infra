variable "name" {
  description = "Resource name prefix, e.g. cs-beta-use1-web. Used for the S3 bucket and as a tag."
  type        = string
}

variable "domain_name" {
  description = "CloudFront alternate domain name (CNAME), e.g. beta.curry.space."
  type        = string
}

variable "cert_arn" {
  description = "ACM certificate ARN in us-east-1 covering domain_name."
  type        = string
}

variable "web_acl_arn" {
  description = "CLOUDFRONT-scope WAF Web ACL ARN to associate with this distribution."
  type        = string
}

variable "price_class" {
  description = "CloudFront price class."
  type        = string
  default     = "PriceClass_100"
}

variable "logs_bucket_domain_name" {
  description = "S3 bucket regional domain name (bucket-name.s3.amazonaws.com) to send standard access logs to."
  type        = string
}

variable "logs_prefix" {
  description = "Prefix within the logs bucket, e.g. cloudfront-web/ or cloudfront-admin/."
  type        = string
}

variable "enable_noindex" {
  description = "Attach an X-Robots-Tag: noindex, nofollow response header. Set true for the admin distribution."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
