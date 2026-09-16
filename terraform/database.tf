resource "aws_db_subnet_group" "this" {
  name       = "${local.name_prefix}-aurora"
  subnet_ids = aws_subnet.data[*].id
  tags       = { Name = "${local.name_prefix}-aurora-subnet-group" }
}

resource "aws_rds_cluster_parameter_group" "this" {
  name   = "${local.name_prefix}-aurora-pg"
  family = "aurora-postgresql15"

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }
}

# "15.4" (this plan's original pin) was deprecated by AWS between the plan
# being written and applied — CreateDBCluster rejected it outright. Resolve
# the latest available 15.x version at apply time instead of hardcoding one,
# since AWS retires minor versions on its own schedule.
data "aws_rds_engine_version" "aurora_postgresql" {
  engine  = "aurora-postgresql"
  version = "15"
  latest  = true
}

resource "aws_rds_cluster" "this" {
  cluster_identifier              = "${local.name_prefix}-aurora-cluster"
  engine                          = "aurora-postgresql"
  engine_version                  = data.aws_rds_engine_version.aurora_postgresql.version_actual
  master_username                 = "dbadmin"
  master_password                 = random_password.db_master.result
  db_subnet_group_name            = aws_db_subnet_group.this.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name
  storage_encrypted               = true
  deletion_protection             = var.environment == "production"
  backup_retention_period         = var.aurora_backup_retention_days
  preferred_backup_window         = "06:00-07:00"
  preferred_maintenance_window    = "sun:07:00-sun:08:00"
  enabled_cloudwatch_logs_exports = ["postgresql"]
  skip_final_snapshot             = var.environment != "production"
}

resource "aws_rds_cluster_instance" "this" {
  count                = var.aurora_instance_count
  identifier           = "${local.name_prefix}-aurora-${count.index}"
  cluster_identifier   = aws_rds_cluster.this.id
  instance_class       = var.aurora_instance_class
  engine               = aws_rds_cluster.this.engine
  engine_version       = aws_rds_cluster.this.engine_version
  db_subnet_group_name = aws_db_subnet_group.this.name
  # Performance Insights isn't supported on t4g classes (production uses
  # r7g and is the only environment that gets it — architecture doc §12.1).
  performance_insights_enabled = var.environment == "production"
  # AWS rejects a non-zero monitoring_interval without a matching
  # monitoring_role_arn (InvalidParameterCombination) — terraform validate
  # doesn't catch this, only a real apply does. Both must be conditional
  # together, not just the role.
  monitoring_interval = var.environment == "production" ? 60 : 0
  monitoring_role_arn = var.environment == "production" ? aws_iam_role.rds_enhanced_monitoring[0].arn : null
}

resource "aws_iam_role" "rds_enhanced_monitoring" {
  count = var.environment == "production" ? 1 : 0
  name  = "${local.name_prefix}-rds-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "rds_enhanced_monitoring" {
  count      = var.environment == "production" ? 1 : 0
  role       = aws_iam_role.rds_enhanced_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# RDS Proxy was planned here (architecture doc §12.7: multiplexes task
# connections, holds them open across a failover) but was never actually
# applied — confirmed 2026-09-16 via both a direct AWS check (zero
# aws_db_proxy resources exist in this account) and the beta state file
# itself (no aws_db_proxy* resources tracked). api/worker/scheduler/migrate
# reach Aurora directly today (networking.tf) and that path is verified
# working (readyz green, migrations applied, real traffic served) — this
# reverts the unapplied proxy design rather than leaving dead code that
# `terraform plan` perpetually wants to create out from under a working
# database_url. Re-introducing a real RDS Proxy is a legitimate future
# project; it should be its own deliberate apply, not implied by unrelated
# work discovering the drift.
