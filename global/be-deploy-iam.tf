# Separate from cs-fe-deploy and cs-infra-deploy on purpose: this role only
# ever needs to push one image to the shared ECR repo and roll ECS services
# onto it — it has no S3/CloudFront/WAF/DNS/ACM access at all.
data "aws_iam_policy_document" "be_deploy_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [data.aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Same org/repo-ID sub claim format as cs-fe-deploy (decisions.md D-007).
    # <rest> is "environment:<name>" once the deploy workflow sets
    # `environment:`, matching the FE repos' pattern.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:Curry-Studio@269430660/curryspacebe@1311717969:*",
      ]
    }
  }
}

resource "aws_iam_role" "be_deploy" {
  name               = "cs-be-deploy"
  assume_role_policy = data.aws_iam_policy_document.be_deploy_trust.json
}

locals {
  # cs-<env>-use1-<component> — the naming convention from terraform/locals.tf
  # and compute.tf. Hardcoded here rather than looked up via remote state,
  # same reasoning as cs-fe-deploy's fe_bucket_arns: fully determined by the
  # naming convention, so this role doesn't need staging/production to
  # already be applied for its policy to be correct.
  be_environments = ["beta", "staging", "production"]

  be_service_arns = [
    for env in local.be_environments : [
      for svc in ["api", "worker", "scheduler"] :
      "arn:aws:ecs:us-east-1:${data.aws_caller_identity.current.account_id}:service/cs-${env}-use1-cluster/cs-${env}-use1-${svc}"
    ]
  ]

  be_task_role_arns = flatten([
    for env in local.be_environments : [
      for role in ["execution-role", "api-task-role", "worker-task-role", "scheduler-task-role", "migrate-task-role"] :
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/cs-${env}-use1-${role}"
    ]
  ])
}

data "aws_iam_policy_document" "be_deploy_permissions" {
  statement {
    sid       = "EcrAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"] # this specific action doesn't support resource scoping
  }

  statement {
    # DescribeImages is what deploy.yml's "Check for an existing image tag"
    # step uses to detect a re-run against a commit that already pushed
    # (ECR's tag immutability rejects a second push of the same sha-<sha>
    # tag otherwise) -- missing here meant that check silently
    # AccessDenied'd every time (swallowed by its own `>/dev/null 2>&1`),
    # so `exists` was always false and a re-run always attempted a real
    # rebuild+push, hard-failing on the immutable-tag error instead of
    # reusing the existing image as designed. Never surfaced until
    # 2026-09-16, the first time deploy.yml was re-run for an
    # already-pushed commit since tag immutability was turned on.
    sid    = "EcrPushPull"
    effect = "Allow"
    actions = [
      "ecr:DescribeImages",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:PutImage",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
    ]
    resources = [aws_ecr_repository.app.arn]
  }

  statement {
    sid    = "EcsDeploy"
    effect = "Allow"
    actions = [
      "ecs:RegisterTaskDefinition", # no resource-level permissions support
      "ecs:DescribeTaskDefinition", # same
    ]
    resources = ["*"]
  }

  statement {
    sid       = "EcsUpdateService"
    effect    = "Allow"
    actions   = ["ecs:UpdateService", "ecs:DescribeServices"]
    resources = flatten(local.be_service_arns)
  }

  statement {
    # register-task-definition needs to pass the execution role and each
    # service's task role — scoped to exactly those roles, and further
    # restricted to only being passed to ECS tasks, not any AWS service.
    sid       = "PassEcsRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.be_task_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    # RunTask supports resource-level permissions on the task definition
    # (family:revision, or family:* for "any revision of this family") plus
    # an ecs:cluster condition — scoped to exactly the migrate family in
    # each environment's cluster, nothing else this role could run.
    sid     = "EcsRunMigrateTask"
    effect  = "Allow"
    actions = ["ecs:RunTask"]
    resources = [
      for env in local.be_environments :
      "arn:aws:ecs:us-east-1:${data.aws_caller_identity.current.account_id}:task-definition/cs-${env}-use1-migrate:*"
    ]

    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values = [
        for env in local.be_environments :
        "arn:aws:ecs:us-east-1:${data.aws_caller_identity.current.account_id}:cluster/cs-${env}-use1-cluster"
      ]
    }
  }

  statement {
    # deploy.yml polls the migrate task via `aws ecs wait tasks-stopped` +
    # `describe-tasks` to read its exit code — task ARNs aren't known until
    # RunTask returns one, so this is scoped to "any task in this cluster",
    # not a specific ARN.
    sid     = "EcsDescribeMigrateTasks"
    effect  = "Allow"
    actions = ["ecs:DescribeTasks"]
    resources = [
      for env in local.be_environments :
      "arn:aws:ecs:us-east-1:${data.aws_caller_identity.current.account_id}:task/cs-${env}-use1-cluster/*"
    ]
  }

  statement {
    # deploy.yml looks up the migrate task's subnets/security group by the
    # cs-<env>-use1-* naming convention at runtime, same env-agnostic
    # approach as everything else in this role, rather than hardcoding IDs.
    sid       = "Ec2DescribeNetworking"
    effect    = "Allow"
    actions   = ["ec2:DescribeSubnets", "ec2:DescribeSecurityGroups"]
    resources = ["*"] # neither action supports resource-level scoping
  }

  statement {
    sid       = "Identity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "be_deploy_permissions" {
  name   = "cs-be-deploy-permissions"
  role   = aws_iam_role.be_deploy.id
  policy = data.aws_iam_policy_document.be_deploy_permissions.json
}

output "be_deploy_role_arn" {
  description = "Set as the AWS_ROLE_ARN repo variable in curryspacebe."
  value       = aws_iam_role.be_deploy.arn
}
