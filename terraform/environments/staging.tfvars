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

redis_node_type     = "cache.t4g.medium"
redis_replica_count = 1

# Doc §17.3: 1 vCPU / 2GB, API autoscales 2-4.
api_cpu       = 1024
api_memory    = 2048
api_min_count = 2
api_max_count = 4

worker_cpu       = 1024
worker_memory    = 2048
worker_min_count = 1
worker_max_count = 1

scheduler_cpu    = 1024
scheduler_memory = 2048
