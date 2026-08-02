# No confirmed endpoint (email/Slack) to page yet — this topic exists so
# alarms have somewhere to publish to, but nobody is subscribed. Follow-up:
# aws sns subscribe once there's a real destination.
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

# BullMQ job keys carry no TTL, so under memory pressure with the wrong
# eviction policy they'd be evicted instead of expiring — this is the
# alarm that catches getting maxmemory-policy wrong before jobs silently
# vanish (architecture doc §11.6).
resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${local.name_prefix}-redis-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Average"
  threshold           = 75
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.this.replication_group_id
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  alarm_name          = "${local.name_prefix}-redis-evictions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.this.replication_group_id
  }
}

# Only meaningful with a reader to lag behind the writer — beta has none
# (aurora_instance_count = 1), so this alarm isn't created for beta. It
# exists ready for when production (aurora_instance_count = 2) applies.
resource "aws_cloudwatch_metric_alarm" "aurora_replica_lag" {
  count               = var.aurora_instance_count > 1 ? 1 : 0
  alarm_name          = "${local.name_prefix}-aurora-replica-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 1000 # milliseconds — architecture doc §12.3 alarms above 1 second
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.this.cluster_identifier
  }
}
