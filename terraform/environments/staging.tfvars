environment = "staging"

state_bucket = "cs-tfstate-REPLACE_WITH_ACCOUNT_ID"

# Doc §6.1: staging adds rate limiting on top of the managed rule groups.
enable_rate_limiting = true

# D-005: open admin access everywhere until real CIDRs exist.
admin_waf_default_action = "ALLOW"
admin_allowed_ip_set     = []
