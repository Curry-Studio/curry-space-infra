environment = "production"

state_bucket = "cs-tfstate-670794226662"

enable_rate_limiting = true

# D-005: open admin access everywhere until real CIDRs exist. Revisit before
# real production launch — this is the environment where it matters most.
admin_waf_default_action = "ALLOW"
admin_allowed_ip_set     = []

vpc_cidr = "10.0.0.0/16"
az_count = 3
