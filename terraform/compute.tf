resource "aws_ecs_cluster" "this" {
  name = "${local.name_prefix}-cluster"

  setting {
    name  = "containerInsights"
    value = var.environment == "beta" ? "disabled" : "enabled"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]
}

# --- IAM: one execution role shared by all three services, one task role
# per service, each scoped to specific ARNs (architecture doc §19.1).

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name_prefix}-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# Shared nonprod/prod media bucket and the shared ECR repo (decisions.md
# D-008), both created in global/ by Task 2 — literal strings, not
# Terraform state references, since both names are fully deterministic.
locals {
  media_bucket_name = "cs-${var.environment == "production" ? "prod" : "nonprod"}-use1-media"
  ecr_image_uri     = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com/cs/app:placeholder"
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "${local.name_prefix}-execution-secrets"
  role = aws_iam_role.execution.id

  # The execution role needs GetSecretValue on whatever's actually injected
  # into a container's `secrets` block below -- database_url/redis_url/
  # cookie_secret, not db_app/redis_auth directly (see secrets.tf).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.database_url.arn,
        aws_secretsmanager_secret.redis_url.arn,
        aws_secretsmanager_secret.cookie_secret.arn,
      ]
    }]
  })
}

resource "aws_iam_role" "api_task" {
  name               = "${local.name_prefix}-api-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "api_task" {
  name = "${local.name_prefix}-api-task-policy"
  role = aws_iam_role.api_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = ["arn:aws:s3:::${local.media_bucket_name}/media/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_app.arn, aws_secretsmanager_secret.redis_auth.arn, aws_secretsmanager_secret.jwt.arn]
      }
    ]
  })
}

resource "aws_iam_role" "worker_task" {
  name               = "${local.name_prefix}-worker-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "worker_task" {
  name = "${local.name_prefix}-worker-task-policy"
  role = aws_iam_role.worker_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = ["arn:aws:s3:::${local.media_bucket_name}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "sns:Publish"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [aws_secretsmanager_secret.db_app.arn, aws_secretsmanager_secret.redis_auth.arn]
      }
    ]
  })
}

resource "aws_iam_role" "scheduler_task" {
  name               = "${local.name_prefix}-scheduler-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "scheduler_task" {
  name = "${local.name_prefix}-scheduler-task-policy"
  role = aws_iam_role.scheduler_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [aws_secretsmanager_secret.db_app.arn, aws_secretsmanager_secret.redis_auth.arn]
    }]
  })
}

# --- The three services. Same image, different command — the migration
# task shape (dist/migrate.js, run once per deploy, not a service) is out
# of scope for this Terraform-only phase; it belongs to the future deploy
# pipeline, not a standing ECS service.

locals {
  # curryspacebe's env schema (src/config/env.ts) requires DATABASE_URL,
  # REDIS_URL, and COOKIE_SECRET as single connection-string/secret values,
  # not a host plus a separate credentials secret -- see secrets.tf for how
  # these are assembled.
  shared_secrets = [
    { name = "DATABASE_URL", valueFrom = aws_secretsmanager_secret.database_url.arn },
    { name = "REDIS_URL", valueFrom = aws_secretsmanager_secret.redis_url.arn },
    { name = "COOKIE_SECRET", valueFrom = aws_secretsmanager_secret.cookie_secret.arn },
  ]
  shared_env = [
    { name = "NODE_ENV", value = var.environment == "production" ? "production" : "development" },
    { name = "AWS_REGION", value = var.aws_region },
    { name = "DB_SSL", value = "true" },
  ]
}

module "api_service" {
  source = "./modules/ecs_service"

  name               = "${local.name_prefix}-api"
  cluster_arn        = aws_ecs_cluster.this.arn
  image              = local.ecr_image_uri
  command            = ["node", "dist/index.js"]
  container_port     = 3000
  cpu                = var.api_cpu
  memory             = var.api_memory
  min_count          = var.api_min_count
  max_count          = var.api_max_count
  subnet_ids         = aws_subnet.app[*].id
  security_group_id  = aws_security_group.api.id
  task_role_arn      = aws_iam_role.api_task.arn
  execution_role_arn = aws_iam_role.execution.arn
  target_group_arn   = aws_lb_target_group.api.arn
  region             = var.aws_region
  environment_vars   = local.shared_env
  secrets            = local.shared_secrets

  capacity_provider_strategy = [{ capacity_provider = "FARGATE", weight = 1 }]

  # FARGATE/FARGATE_SPOT must be associated with the cluster (a separate
  # resource from aws_ecs_cluster itself) before a service's
  # capacity_provider_strategy can reference them — otherwise AWS can
  # reject service creation with a race between the two resources.
  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

module "worker_service" {
  source = "./modules/ecs_service"

  name               = "${local.name_prefix}-worker"
  cluster_arn        = aws_ecs_cluster.this.arn
  image              = local.ecr_image_uri
  command            = ["node", "dist/worker.js"]
  cpu                = var.worker_cpu
  memory             = var.worker_memory
  min_count          = var.worker_min_count
  max_count          = var.worker_max_count
  subnet_ids         = aws_subnet.app[*].id
  security_group_id  = aws_security_group.worker.id
  task_role_arn      = aws_iam_role.worker_task.arn
  execution_role_arn = aws_iam_role.execution.arn
  region             = var.aws_region
  environment_vars   = local.shared_env
  secrets            = local.shared_secrets

  # Base 2 on-demand then FARGATE_SPOT only matters once worker_max_count
  # exceeds 2 (production). Beta/staging run a single task, all FARGATE.
  capacity_provider_strategy = var.worker_max_count > 2 ? [
    { capacity_provider = "FARGATE", weight = 0, base = 2 },
    { capacity_provider = "FARGATE_SPOT", weight = 1 },
  ] : [{ capacity_provider = "FARGATE", weight = 1 }]

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}

module "scheduler_service" {
  source = "./modules/ecs_service"

  name                               = "${local.name_prefix}-scheduler"
  cluster_arn                        = aws_ecs_cluster.this.arn
  image                              = local.ecr_image_uri
  command                            = ["node", "dist/scheduler.js"]
  cpu                                = var.scheduler_cpu
  memory                             = var.scheduler_memory
  min_count                          = 1
  max_count                          = 1
  subnet_ids                         = aws_subnet.app[*].id
  security_group_id                  = aws_security_group.scheduler.id
  task_role_arn                      = aws_iam_role.scheduler_task.arn
  execution_role_arn                 = aws_iam_role.execution.arn
  region                             = var.aws_region
  environment_vars                   = local.shared_env
  secrets                            = local.shared_secrets
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100 # old task stops before the new one starts — never two schedulers at once

  capacity_provider_strategy = [{ capacity_provider = "FARGATE", weight = 1 }]

  depends_on = [aws_ecs_cluster_capacity_providers.this]
}
