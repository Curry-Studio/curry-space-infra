environment = "production"

state_bucket = "cs-tfstate-670794226662"

enable_rate_limiting = true

# D-005: open admin access everywhere until real CIDRs exist. Revisit before
# real production launch — this is the environment where it matters most.
admin_waf_default_action = "ALLOW"
admin_allowed_ip_set     = []

vpc_cidr = "10.0.0.0/16"
az_count = 3

aurora_instance_class        = "db.r7g.large"
aurora_instance_count        = 2
aurora_backup_retention_days = 35

redis_node_type     = "cache.r7g.large"
redis_replica_count = 1

# Doc §17.4 / §8.4.
api_cpu       = 1024
api_memory    = 2048
api_min_count = 2
api_max_count = 20

worker_cpu       = 2048
worker_memory    = 4096
worker_min_count = 2
worker_max_count = 10

scheduler_cpu    = 512
scheduler_memory = 1024
