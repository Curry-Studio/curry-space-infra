locals {
  region_short = "use1" # us-east-1. See architecture doc §2.4 for the naming convention.
  name_prefix  = "cs-${var.environment}-${local.region_short}"

  # Flat hostname pattern (architecture doc §4.3): a single *.curry.space
  # wildcard covers every environment because nothing is nested under a
  # per-environment subdomain.
  web_domain   = var.environment == "production" ? "curry.space" : "${var.environment}.curry.space"
  admin_domain = var.environment == "production" ? "admin.curry.space" : "${var.environment}-admin.curry.space"

  cert_arn = data.terraform_remote_state.global.outputs.wildcard_cert_arn
  zone_id  = data.terraform_remote_state.global.outputs.zone_id
}
