variable "name" {
  description = "Resource name prefix, e.g. cs-beta-use1-web. Used for the S3 bucket and as a tag."
  type        = string
}

variable "domain_names" {
  description = "CloudFront alternate domain names (CNAMEs). The web distribution gets both its app hostname and its API hostname; admin gets just its own."
  type        = list(string)
}

variable "alb_origin_domain_name" {
  description = "ALB DNS name. When set, adds an ALB origin and a /api/* behavior. Leave null for distributions with no API path (admin)."
  type        = string
  default     = null
}

variable "origin_verify_header_value" {
  description = "Value CloudFront sends as X-Origin-Verify to the ALB origin. Required if alb_origin_domain_name is set."
  type        = string
  default     = null
  sensitive   = true
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
