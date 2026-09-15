variable "preview_name" {
  description = "Short name for this preview environment, e.g. \"proto\". Used as the subdomain (<preview_name>.curry.space) and in every resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.preview_name))
    error_message = "preview_name must be lowercase alphanumeric (with hyphens), starting with a letter, 2-21 characters."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "Name of the S3 bucket created by ../bootstrap, used to read global/terraform.tfstate. Same account for every stack (D-001)."
  type        = string
}
