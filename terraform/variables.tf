variable "environment" {
  description = "beta, staging, or production."
  type        = string

  validation {
    condition     = contains(["beta", "staging", "production"], var.environment)
    error_message = "environment must be one of: beta, staging, production."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "Name of the S3 bucket created by ../bootstrap, used to read global/terraform.tfstate. Same account for every environment (D-001), so this value doesn't change between beta/staging/production.tfvars."
  type        = string
}

variable "admin_waf_default_action" {
  description = "Default action on the admin Web ACL. Target design is BLOCK with an IP allow-list; currently ALLOW everywhere per decisions.md D-005 until real CIDRs are supplied. Flip this per-environment as ranges become available."
  type        = string
  default     = "ALLOW"

  validation {
    condition     = contains(["ALLOW", "BLOCK"], var.admin_waf_default_action)
    error_message = "admin_waf_default_action must be ALLOW or BLOCK."
  }
}

variable "admin_allowed_ip_set" {
  description = "CIDR ranges allowed through when admin_waf_default_action is BLOCK. Ignored (and can stay empty) while it's ALLOW. Not yet populated — see decisions.md D-005."
  type        = list(string)
  default     = []
}

variable "enable_rate_limiting" {
  description = "Adds the general 2,000-req/5-min WAF rate limit rule. Doc §6.1: off for beta, on for staging and production."
  type        = bool
  default     = false
}

variable "vpc_cidr" {
  description = "VPC CIDR block. Beta 10.10.0.0/16, staging 10.20.0.0/16, production 10.0.0.0/16 — non-overlapping across environments (architecture doc §3.1)."
  type        = string
}

variable "az_count" {
  description = "Number of AZs to spread subnets across. 2 for beta/staging, 3 for production."
  type        = number
  default     = 2
}

variable "aurora_instance_class" {
  description = "db.t4g.medium (beta), db.t4g.large (staging), db.r7g.large (production) — architecture doc §17.2-17.4."
  type        = string
}

variable "aurora_instance_count" {
  description = "1 = writer only (beta, staging). 2 = writer + 1 reader (production)."
  type        = number
  default     = 1
}

variable "aurora_backup_retention_days" {
  type = number
}
