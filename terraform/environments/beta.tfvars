environment = "beta"

# cs-tfstate-<account-id>, created by the bootstrap run. Same in all three
# tfvars files — one account (D-001). Account: Curry Labs AI Inc, 670794226662.
state_bucket = "cs-tfstate-670794226662"

# Doc §6.1: beta gets managed core rules only, no rate limiting.
enable_rate_limiting = false

# D-005: open admin access everywhere until real CIDRs exist.
admin_waf_default_action = "ALLOW"
admin_allowed_ip_set     = []

vpc_cidr = "10.10.0.0/16"
az_count = 2
