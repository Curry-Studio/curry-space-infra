environment = "beta"

# Fill in after `terraform apply` in ../../bootstrap (its state_bucket_name output).
# Same value in staging.tfvars and production.tfvars — one account (D-001).
state_bucket = "cs-tfstate-REPLACE_WITH_ACCOUNT_ID"

# Doc §6.1: beta gets managed core rules only, no rate limiting.
enable_rate_limiting = false

# D-005: open admin access everywhere until real CIDRs exist.
admin_waf_default_action = "ALLOW"
admin_allowed_ip_set     = []
