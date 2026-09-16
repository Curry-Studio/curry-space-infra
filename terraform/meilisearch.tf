# Search (spec 0016) — self-hosted Meilisearch, one Fargate task, EFS-backed
# so the index survives task restarts/redeploys (there is no managed
# Meilisearch service to point at instead — arch §8 calls for self-hosted).
# Reached only via the internal Cloud Map DNS name below, never a public
# endpoint; api/worker/scheduler each derive their own scoped key from
# MEILI_MASTER_KEY (secrets.tf) at boot, per the spec's key-derivation design.
#
# Deliberately NOT built on the shared ./modules/ecs_service module used by
# api/worker/scheduler — that module has no EFS volume or service-discovery
# support, and threading those through as options would touch every existing
# service's blast radius for a single new consumer. Plain resources here
# instead, mirroring the module's own conventions (log group naming, ARM64,
# circuit-breaker deploys) so it still reads like the rest of this file.

resource "aws_efs_file_system" "meilisearch" {
  creation_token = "${local.name_prefix}-meilisearch"
  encrypted      = true
  tags           = { Name = "${local.name_prefix}-meilisearch-data" }
}

resource "aws_efs_mount_target" "meilisearch" {
  count           = var.az_count
  file_system_id  = aws_efs_file_system.meilisearch.id
  subnet_id       = aws_subnet.data[count.index].id
  security_groups = [aws_security_group.meili_efs.id]
}

# Internal-only service discovery so api/worker/scheduler can reach
# Meilisearch by a stable DNS name instead of a task IP that changes on every
# deploy. One namespace is enough for now; a future second internal service
# would just add another aws_service_discovery_service under it.
resource "aws_service_discovery_private_dns_namespace" "internal" {
  name = "${var.environment}.cs.internal"
  vpc  = aws_vpc.this.id
}

resource "aws_service_discovery_service" "meilisearch" {
  name = "meilisearch"

  dns_config {
    namespace_id = aws_service_discovery_private_dns_namespace.internal.id
    dns_records {
      ttl  = 10
      type = "A"
    }
    routing_policy = "MULTIVALUE"
  }

  health_check_custom_config {
    failure_threshold = 1
  }
}

locals {
  # http:// (not https) — this never leaves the VPC, so TLS between
  # api/worker/scheduler and Meilisearch isn't in scope for beta (matches
  # env.ts's own default of http://localhost:7700).
  meili_host = "http://meilisearch.${aws_service_discovery_private_dns_namespace.internal.name}:7700"
}

resource "aws_iam_role" "meilisearch_task" {
  name               = "${local.name_prefix}-meilisearch-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  # No inline policy: Meilisearch makes no AWS API calls of its own at
  # runtime (logs/secrets are the execution role's job, EFS access is
  # security-group-gated, not IAM-gated).
}

resource "aws_cloudwatch_log_group" "meilisearch" {
  name              = "/ecs/${local.name_prefix}-meilisearch"
  retention_in_days = 14
}

resource "aws_ecs_task_definition" "meilisearch" {
  family                   = "${local.name_prefix}-meilisearch"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.meili_cpu
  memory                   = var.meili_memory
  task_role_arn            = aws_iam_role.meilisearch_task.arn
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  volume {
    name = "meili-data"
    efs_volume_configuration {
      file_system_id = aws_efs_file_system.meilisearch.id
      root_directory = "/"
    }
  }

  container_definitions = jsonencode([{
    name = "meilisearch"
    # Same tag as the local docker-compose service (spec 0002) so beta
    # behaves like dev, not a different untested version.
    image        = "getmeili/meilisearch:v1.10"
    essential    = true
    portMappings = [{ containerPort = 7700, protocol = "tcp" }]
    environment = [
      { name = "MEILI_NO_ANALYTICS", value = "true" },
      # production enforces MEILI_MASTER_KEY on every request; without this
      # Meilisearch only warns and keeps serving unauthenticated (fine for
      # local dev, not for a shared beta instance reachable from 3 services).
      { name = "MEILI_ENV", value = "production" },
    ]
    secrets = [
      { name = "MEILI_MASTER_KEY", valueFrom = aws_secretsmanager_secret.meili_master_key.arn },
    ]
    mountPoints = [{ sourceVolume = "meili-data", containerPath = "/meili_data" }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.meilisearch.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "meilisearch" {
  name                   = "${local.name_prefix}-meilisearch"
  cluster                = aws_ecs_cluster.this.arn
  task_definition        = aws_ecs_task_definition.meilisearch.arn
  desired_count          = 1
  platform_version       = "LATEST" # >= 1.4.0 required for EFS volumes on Fargate
  enable_execute_command = true

  capacity_provider_strategy {
    capacity_provider = "FARGATE" # not Spot — avoid interrupting the one instance holding the index
    weight            = 1
  }

  network_configuration {
    subnets         = aws_subnet.app[*].id
    security_groups = [aws_security_group.meilisearch.id]
  }

  service_registries {
    registry_arn = aws_service_discovery_service.meilisearch.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  # No target group (never behind the ALB — internal only) and no
  # autoscaling target: one Meilisearch instance, matching the scheduler's
  # single-instance treatment elsewhere in this file.

  depends_on = [
    aws_ecs_cluster_capacity_providers.this,
    aws_efs_mount_target.meilisearch,
  ]
}
