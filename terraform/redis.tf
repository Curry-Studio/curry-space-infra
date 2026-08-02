resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-redis"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_elasticache_parameter_group" "this" {
  name   = "${local.name_prefix}-redis-pg"
  family = "redis7"

  # volatile-lru only evicts keys with an explicit TTL. BullMQ job keys
  # have no TTL, so under allkeys-lru they'd be evicted under memory
  # pressure and queued work would silently disappear (architecture doc
  # §11.1 — this is called out as the single most important Redis setting).
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id       = "${local.name_prefix}-redis"
  description                = "Curry Space ${var.environment} — cache, sessions, BullMQ"
  engine                     = "redis"
  engine_version             = "7.1"
  node_type                  = var.redis_node_type
  num_cache_clusters         = 1 + var.redis_replica_count
  automatic_failover_enabled = var.redis_replica_count > 0
  multi_az_enabled           = var.redis_replica_count > 0
  subnet_group_name          = aws_elasticache_subnet_group.this.name
  security_group_ids         = [aws_security_group.redis.id]
  parameter_group_name       = aws_elasticache_parameter_group.this.name
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  snapshot_retention_limit   = var.environment == "production" ? 7 : 0
  snapshot_window            = "08:00-09:00"
}
