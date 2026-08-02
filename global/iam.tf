# The OIDC provider itself already exists in this account and is tested
# (decisions.md D-003) — looked up, not created, so this config can't
# accidentally conflict with it.
data "aws_iam_openid_connect_provider" "github" {
  url = "https://token.actions.githubusercontent.com"
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "github_actions_trust" {
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

    # Allows the apply path (pushes to main) and the plan path (any PR
    # against this repo). Scoped to one repo — curry-space-infra — not
    # the whole GitHub org.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:Curry-Studio/curry-space-infra:ref:refs/heads/main",
        "repo:Curry-Studio/curry-space-infra:pull_request",
      ]
    }
  }
}

resource "aws_iam_role" "github_actions_deploy" {
  name               = "cs-infra-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_actions_trust.json
}

# Scoped to what phase 1 (front-end: S3/CloudFront/WAF/Route53/ACM) touches,
# plus the state backend. Expect to extend this in phase 2 for ECS, Aurora,
# ElastiCache, and VPC permissions — don't reach for a managed
# power-user policy given D-001 (one account, no per-environment blast
# radius from account separation).
data "aws_iam_policy_document" "deploy_permissions" {
  statement {
    sid    = "TerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::cs-tfstate-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::cs-tfstate-${data.aws_caller_identity.current.account_id}/*",
    ]
  }

  statement {
    sid    = "TerraformLock"
    effect = "Allow"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:DeleteItem",
    ]
    resources = ["arn:aws:dynamodb:*:${data.aws_caller_identity.current.account_id}:table/cs-tfstate-lock"]
  }

  statement {
    sid    = "FrontEndInfra"
    effect = "Allow"
    actions = [
      "s3:*",
      "cloudfront:*",
      "wafv2:*",
      "route53:*",
      "acm:*",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "Identity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy_permissions" {
  name   = "cs-infra-deploy-permissions"
  role   = aws_iam_role.github_actions_deploy.id
  policy = data.aws_iam_policy_document.deploy_permissions.json
}
