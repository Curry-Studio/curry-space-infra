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

aurora_instance_class        = "db.t4g.medium"
aurora_instance_count        = 1
aurora_backup_retention_days = 1

redis_node_type     = "cache.t4g.small"
redis_replica_count = 0

# Doc §17.2: 0.5 vCPU / 1GB per service, 1 task each, no autoscaling.
api_cpu       = 512
api_memory    = 1024
api_min_count = 1
api_max_count = 1

worker_cpu       = 512
worker_memory    = 1024
worker_min_count = 1
worker_max_count = 1

scheduler_cpu    = 512
scheduler_memory = 1024
