resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${local.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-igw" }
}

resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = local.public_subnet_cidrs[count.index]
  availability_zone       = local.availability_zones[count.index]
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name_prefix}-public-${substr(local.availability_zones[count.index], -1, 1)}" }
}

resource "aws_subnet" "app" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.app_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]
  tags              = { Name = "${local.name_prefix}-app-${substr(local.availability_zones[count.index], -1, 1)}" }
}

resource "aws_subnet" "data" {
  count             = var.az_count
  vpc_id            = aws_vpc.this.id
  cidr_block        = local.data_subnet_cidrs[count.index]
  availability_zone = local.availability_zones[count.index]
  tags              = { Name = "${local.name_prefix}-data-${substr(local.availability_zones[count.index], -1, 1)}" }
}

# One NAT Gateway per AZ in production, a single one everywhere else
# (architecture doc §3.6 — beta/staging accept the single point of failure).
resource "aws_eip" "nat" {
  count  = var.environment == "production" ? var.az_count : 1
  domain = "vpc"
  tags   = { Name = "${local.name_prefix}-nat-eip-${count.index}" }
}

resource "aws_nat_gateway" "this" {
  count         = var.environment == "production" ? var.az_count : 1
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
  tags          = { Name = "${local.name_prefix}-nat-${count.index}" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name_prefix}-rt-public" }
}

resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# One app route table per AZ so each AZ's traffic goes out its own NAT
# Gateway rather than crossing AZs (matches architecture doc §3.7). In
# beta/staging (single NAT), every AZ's table points at the same gateway.
resource "aws_route_table" "app" {
  count  = var.az_count
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this[var.environment == "production" ? count.index : 0].id
  }
  tags = { Name = "${local.name_prefix}-rt-app-${substr(local.availability_zones[count.index], -1, 1)}" }
}

resource "aws_route_table_association" "app" {
  count          = var.az_count
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app[count.index].id
}

# Data subnets get no default route at all — no NAT, no internet. Aurora
# and Redis never need to call out (architecture doc §3.4).
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name_prefix}-rt-data" }
}

resource "aws_route_table_association" "data" {
  count          = var.az_count
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# VPC endpoints — the doc calls these out by name as paying for themselves
# (§3.6): S3 (gateway, free), ECR api/dkr, logs, secretsmanager (interface).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(aws_route_table.app[*].id, [aws_route_table.data.id])
  tags              = { Name = "${local.name_prefix}-vpce-s3" }
}

locals {
  interface_endpoints = ["ecr.api", "ecr.dkr", "logs", "secretsmanager"]
}

resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${local.name_prefix}-vpce-"
  vpc_id      = aws_vpc.this.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = { Name = "${local.name_prefix}-vpce-sg" }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = toset(local.interface_endpoints)
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.app[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name_prefix}-vpce-${each.value}" }
}

# --- Security groups. Every rule references another security group, never
# a CIDR block, so rules stay correct as addresses change underneath them
# (architecture doc §3.8). Graph: sg-alb -> sg-api -> sg-rds-proxy ->
# sg-aurora, with sg-worker/sg-scheduler reaching sg-rds-proxy and sg-redis
# directly and accepting no inbound traffic at all.

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name_prefix = "${local.name_prefix}-alb-"
  vpc_id      = aws_vpc.this.id

  tags = { Name = "${local.name_prefix}-sg-alb" }
}

resource "aws_security_group_rule" "cloudfront_to_alb" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  description       = "HTTPS from CloudFront only - not the open internet"
}

resource "aws_security_group" "api" {
  name_prefix = "${local.name_prefix}-api-"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-sg-api" }
}

resource "aws_security_group_rule" "alb_to_api" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.api.id
  source_security_group_id = aws_security_group.alb.id
  description              = "From the ALB"
}

resource "aws_security_group_rule" "alb_egress_to_api" {
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.api.id
  description              = "To API tasks"
}

resource "aws_security_group" "worker" {
  name_prefix = "${local.name_prefix}-worker-"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-sg-worker" }
  # No ingress rules at all — nothing calls the worker directly.
}

resource "aws_security_group" "scheduler" {
  name_prefix = "${local.name_prefix}-scheduler-"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-sg-scheduler" }
}

resource "aws_security_group" "rds_proxy" {
  name_prefix = "${local.name_prefix}-rds-proxy-"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-sg-rds-proxy" }
}

resource "aws_security_group_rule" "api_to_proxy" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_proxy.id
  source_security_group_id = aws_security_group.api.id
}

resource "aws_security_group_rule" "worker_to_proxy" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_proxy.id
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "scheduler_to_proxy" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_proxy.id
  source_security_group_id = aws_security_group.scheduler.id
}

resource "aws_security_group_rule" "api_egress_to_proxy" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.api.id
  source_security_group_id = aws_security_group.rds_proxy.id
}

resource "aws_security_group_rule" "worker_egress_to_proxy" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.rds_proxy.id
}

resource "aws_security_group_rule" "scheduler_egress_to_proxy" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.scheduler.id
  source_security_group_id = aws_security_group.rds_proxy.id
}

resource "aws_security_group" "aurora" {
  name_prefix = "${local.name_prefix}-aurora-"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-sg-aurora" }
}

resource "aws_security_group_rule" "proxy_to_aurora" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.aurora.id
  source_security_group_id = aws_security_group.rds_proxy.id
}

resource "aws_security_group_rule" "proxy_egress_to_aurora" {
  type                     = "egress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds_proxy.id
  source_security_group_id = aws_security_group.aurora.id
}

resource "aws_security_group" "redis" {
  name_prefix = "${local.name_prefix}-redis-"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${local.name_prefix}-sg-redis" }
}

resource "aws_security_group_rule" "api_to_redis" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = aws_security_group.api.id
}

resource "aws_security_group_rule" "worker_to_redis" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = aws_security_group.worker.id
}

resource "aws_security_group_rule" "scheduler_to_redis" {
  type                     = "ingress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.redis.id
  source_security_group_id = aws_security_group.scheduler.id
}

resource "aws_security_group_rule" "api_egress_to_redis" {
  type                     = "egress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.api.id
  source_security_group_id = aws_security_group.redis.id
}

resource "aws_security_group_rule" "worker_egress_to_redis" {
  type                     = "egress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.worker.id
  source_security_group_id = aws_security_group.redis.id
}

resource "aws_security_group_rule" "scheduler_egress_to_redis" {
  type                     = "egress"
  from_port                = 6379
  to_port                  = 6379
  protocol                 = "tcp"
  security_group_id        = aws_security_group.scheduler.id
  source_security_group_id = aws_security_group.redis.id
}

resource "aws_security_group_rule" "api_egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.api.id
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "Third-party APIs via NAT"
}

resource "aws_security_group_rule" "worker_egress_https" {
  type              = "egress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.worker.id
  cidr_blocks       = ["0.0.0.0/0"]
}
