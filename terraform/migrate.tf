# Backend CD (spec 0021) — the gated migrate step. A task DEFINITION only,
# deliberately never a standing aws_ecs_service: deploy.yml registers a new
# revision with the deploy's image and runs it exactly once via
# `aws ecs run-task`, before rolling api/worker/scheduler onto the same
# image, so a failing migration aborts the deploy while the old tasks keep
# serving (spec 0021's acceptance criterion). No lifecycle.ignore_changes is
# needed here (unlike the three services' module) — nothing ever points at
# "the current revision" the way an aws_ecs_service does; deploy.yml always
# runs the exact task definition ARN it just registered.

resource "aws_cloudwatch_log_group" "migrate" {
  name              = "/ecs/${local.name_prefix}-migrate"
  retention_in_days = 14
}

resource "aws_iam_role" "migrate_task" {
  name               = "${local.name_prefix}-migrate-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
  # No inline policy: migrate.ts only talks to Postgres over DATABASE_URL
  # (injected by the execution role, same as api/worker/scheduler) — no
  # other AWS calls.
}

resource "aws_ecs_task_definition" "migrate" {
  family                   = "${local.name_prefix}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  task_role_arn            = aws_iam_role.migrate_task.arn
  execution_role_arn       = aws_iam_role.execution.arn

  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }

  container_definitions = jsonencode([{
    name    = "migrate"
    image   = local.ecr_image_uri # deploy.yml swaps this to the real sha-<sha> tag on every run
    command = ["node", "dist/db/migrate.js"]
    # env.ts validates the whole schema on import regardless of entrypoint
    # (index.js/worker.js/scheduler.js/this) — same shared_env/shared_secrets
    # the three services already use, not a trimmed-down subset.
    essential   = true
    environment = local.shared_env
    secrets     = local.shared_secrets
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.migrate.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}
