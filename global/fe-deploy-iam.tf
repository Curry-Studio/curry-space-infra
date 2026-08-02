# Separate from cs-infra-deploy on purpose: the two front-end repos only
# ever need to sync static files to their buckets and invalidate a cache —
# handing them the same role as this infra repo (which can touch WAF, DNS,
# and certs) would be more power than a static-site pipeline should have.
data "aws_iam_policy_document" "fe_deploy_trust" {
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

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:Curry-Studio/curryspacefe:*",
        "repo:Curry-Studio/curry-space-admin-fe:*",
      ]
    }
  }
}

resource "aws_iam_role" "fe_deploy" {
  name               = "cs-fe-deploy"
  assume_role_policy = data.aws_iam_policy_document.fe_deploy_trust.json
}

locals {
  # cs-<env>-use1-<app>-<account-id> — the naming convention from
  # terraform/locals.tf and modules/cloudfront_spa/main.tf. Hardcoded here
  # rather than looked up via remote state, since it's fully determined by
  # the naming convention and doesn't need staging/production to already
  # be applied for this policy to be correct.
  fe_bucket_arns = flatten([
    for env in ["beta", "staging", "production"] : [
      for app in ["web", "admin"] : [
        "arn:aws:s3:::cs-${env}-use1-${app}-${data.aws_caller_identity.current.account_id}",
        "arn:aws:s3:::cs-${env}-use1-${app}-${data.aws_caller_identity.current.account_id}/*",
      ]
    ]
  ])
}

data "aws_iam_policy_document" "fe_deploy_permissions" {
  statement {
    sid    = "SyncStaticSites"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = local.fe_bucket_arns
  }

  statement {
    # Distribution IDs aren't predictable the way bucket names are (they're
    # AWS-generated), and staging/production haven't necessarily been
    # applied yet when this runs — so this is scoped by action, not
    # resource. Invalidation alone (no distribution config changes) is a
    # low-risk action to leave broad.
    sid       = "InvalidateCache"
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = ["*"]
  }

  statement {
    sid       = "Identity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "fe_deploy_permissions" {
  name   = "cs-fe-deploy-permissions"
  role   = aws_iam_role.fe_deploy.id
  policy = data.aws_iam_policy_document.fe_deploy_permissions.json
}

output "fe_deploy_role_arn" {
  description = "Set as the AWS_ROLE_ARN repo variable in curryspacefe and curry-space-admin-fe."
  value       = aws_iam_role.fe_deploy.arn
}
