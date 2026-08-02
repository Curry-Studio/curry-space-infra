environment = "staging"

state_bucket = "cs-tfstate-670794226662"

# Doc §6.1: staging adds rate limiting on top of the managed rule groups.
enable_rate_limiting = true

# D-005: open admin access everywhere until real CIDRs exist.
admin_waf_default_action = "ALLOW"
admin_allowed_ip_set     = []

vpc_cidr = "10.20.0.0/16"
az_count = 2

aurora_instance_class        = "db.t4g.large"
aurora_instance_count        = 1
aurora_backup_retention_days = 7
