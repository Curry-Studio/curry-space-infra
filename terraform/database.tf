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

resource "aws_rds_cluster" "this" {
  cluster_identifier              = "${local.name_prefix}-aurora-cluster"
  engine                          = "aurora-postgresql"
  engine_version                  = "15.4"
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
  monitoring_interval          = 60
  monitoring_role_arn          = var.environment == "production" ? aws_iam_role.rds_enhanced_monitoring[0].arn : null
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

# --- RDS Proxy: multiplexes hundreds of task connections down to a small
# pool of real database connections, and holds client connections open
# across a failover (architecture doc §12.7).

resource "aws_iam_role" "rds_proxy" {
  name = "${local.name_prefix}-rds-proxy"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "rds_proxy_secrets" {
  name = "${local.name_prefix}-rds-proxy-secrets"
  role = aws_iam_role.rds_proxy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.db_app.arn]
    }]
  })
}

resource "aws_db_proxy" "this" {
  name                   = "${local.name_prefix}-rds-proxy"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.rds_proxy.arn
  vpc_subnet_ids         = aws_subnet.data[*].id
  vpc_security_group_ids = [aws_security_group.rds_proxy.id]
  require_tls            = true

  auth {
    auth_scheme = "SECRETS"
    secret_arn  = aws_secretsmanager_secret.db_app.arn
    iam_auth    = "DISABLED"
  }
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name

  connection_pool_config {
    max_connections_percent      = 100
    max_idle_connections_percent = 50
    connection_borrow_timeout    = 120
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name         = aws_db_proxy.this.name
  target_group_name     = aws_db_proxy_default_target_group.this.name
  db_cluster_identifier = aws_rds_cluster.this.cluster_identifier
}
