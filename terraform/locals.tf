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

  availability_zones = slice(["us-east-1a", "us-east-1b", "us-east-1c"], 0, var.az_count)

  # /20 blocks carved out of the environment's /16: index 0-2 public,
  # 3-5 app, 6-8 data. cidrsubnet() means the same logic produces the
  # right layout for any of the three environments' CIDRs without
  # hardcoding a subnet table per environment (architecture doc §3.2).
  public_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  app_subnet_cidrs    = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 3)]
  data_subnet_cidrs   = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 6)]
}
