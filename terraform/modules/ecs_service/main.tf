resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  task_role_arn            = var.task_role_arn
  execution_role_arn       = var.execution_role_arn
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name         = var.name
    image        = var.image
    command      = var.command
    essential    = true
    portMappings = var.container_port == null ? [] : [{ containerPort = var.container_port, protocol = "tcp" }]
    environment  = var.environment_vars
    secrets      = var.secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.this.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

resource "aws_ecs_service" "this" {
  name                               = var.name
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.this.arn
  desired_count                      = var.min_count
  deployment_minimum_healthy_percent = var.deployment_minimum_healthy_percent
  deployment_maximum_percent         = var.deployment_maximum_percent

  dynamic "capacity_provider_strategy" {
    for_each = var.capacity_provider_strategy
    content {
      capacity_provider = capacity_provider_strategy.value.capacity_provider
      weight            = capacity_provider_strategy.value.weight
      base              = try(capacity_provider_strategy.value.base, null)
    }
  }

  network_configuration {
    subnets         = var.subnet_ids
    security_groups = [var.security_group_id]
  }

  dynamic "load_balancer" {
    for_each = var.target_group_arn == null ? [] : [1]
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.name
      container_port   = var.container_port
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    # desired_count: auto scaling (when enabled) owns this.
    # task_definition: once a real image exists, curryspacebe's own deploy
    # workflow registers new revisions and updates the service directly
    # (register-task-definition + update-service, not a Terraform apply) --
    # Terraform still owns cpu/memory/env/secrets/command via
    # aws_ecs_task_definition.this above, but stops forcing the service
    # back onto that revision's ARN so it doesn't fight CI on every apply.
    ignore_changes = [desired_count, task_definition]
  }
}

resource "aws_appautoscaling_target" "this" {
  count              = var.max_count > var.min_count ? 1 : 0
  service_namespace  = "ecs"
  resource_id        = "service/${split("/", var.cluster_arn)[1]}/${aws_ecs_service.this.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = var.min_count
  max_capacity       = var.max_count
}

# CPU target tracking only. Request-rate (API) and backlog-per-task
# (worker) policies are follow-up work for when staging/production are
# actually applied — see this task's header note.
resource "aws_appautoscaling_policy" "cpu" {
  count              = var.max_count > var.min_count ? 1 : 0
  name               = "${var.name}-cpu-target-tracking"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id        = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  policy_type        = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
  }
}
