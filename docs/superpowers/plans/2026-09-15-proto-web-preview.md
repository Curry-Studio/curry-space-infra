# Proto Web Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up `proto.curry.space` as a lightweight, front-end-only preview environment for `curryspacefe`'s already-existing `proto` branch, without touching beta's API/backend or changing how beta/staging/production build or deploy.

**Architecture:** A new, isolated Terraform root module (`terraform-web-preview/` in `curry-space-infra`) with its own state file provisions an S3 bucket + CloudFront distribution (reusing the existing `modules/cloudfront_spa` module unchanged) + WAF ACL + Route 53 records for `proto.curry.space`. Two existing shared files get small, additive edits (`global/fe-deploy-iam.tf`, `.github/workflows/terraform.yml`); `curryspacefe/.github/workflows/deploy.yml` gets one branch name added. No VPC/ECS/Aurora/Redis/ALB — this environment has no backend.

**Tech Stack:** Terraform ~1.9, AWS provider ~5.0, GitHub Actions (OIDC), GitHub CLI (`gh`) for scripted rollout steps.

**Spec:** `docs/superpowers/specs/2026-09-15-proto-web-preview-design.md`

## Global Constraints

- `preview_name = "proto"` — used as the subdomain (`proto.curry.space`) and in every resource name (`cs-proto-use1-*`).
- State bucket: `cs-tfstate-670794226662` (same account/bucket as every other stack — D-001). Account ID: `670794226662`.
- Region: `us-east-1` everywhere (WAFv2 CLOUDFRONT-scope ACLs must be created here regardless).
- No VPC, ECS, Aurora, Redis, ALB, or `proto-api.curry.space` — front-end only.
- No new ACM certificate or Route 53 zone — the existing wildcard cert and zone (read via `global`'s remote state) already cover `proto.curry.space`.
- `enable_noindex = true` on the proto CloudFront distribution — it's a preview surface.
- Every edit to a file shared with beta/staging/production (`global/fe-deploy-iam.tf`, `curry-space-infra/.github/workflows/terraform.yml`, `curryspacefe/.github/workflows/deploy.yml`) must be strictly additive — existing entries, conditions, and behavior for `beta`/`staging`/`production`/`main` are not to change.
- **Any step that runs `terraform apply`, merges a PR, or pushes directly to a shared branch (`main`, `proto`) is a hard-reverse / outward-facing action — stop and get explicit user confirmation immediately before running it, even though it's written out below.**
- Working directory for all `curry-space-infra` tasks: the already-created branch `feat/proto-web-preview` (currently checked out).

---

## Task 1: Root module skeleton

**Files:**
- Create: `terraform-web-preview/main.tf`
- Create: `terraform-web-preview/variables.tf`
- Create: `terraform-web-preview/locals.tf`
- Create: `terraform-web-preview/environments/proto.tfvars`

**Interfaces:**
- Consumes: `global`'s remote state outputs `wildcard_cert_arn`, `zone_id` (`global/outputs.tf`).
- Produces: `var.preview_name`, `local.name_prefix` (`cs-<preview_name>-use1`), `local.web_domain` (`<preview_name>.curry.space`), `local.cert_arn`, `local.zone_id` — consumed by Tasks 2-6.

- [ ] **Step 1: Install Terraform locally if not already present, and confirm the version floor**

```bash
which terraform || brew install terraform
terraform version
```

Expected: version `>= 1.9` (the repo's `main.tf` `required_version` floor).

- [ ] **Step 2: Write `terraform-web-preview/main.tf`**

```hcl
terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Partial config — bucket/region/dynamodb_table are fixed, key is passed
  # at init time. See ../README.md for the exact command.
  backend "s3" {}
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "curry-space"
      Environment = var.preview_name
      ManagedBy   = "terraform"
      Purpose     = "frontend-preview"
    }
  }
}

# Reads the global config's state to get the shared ACM cert and hosted
# zone ID, same pattern as ../terraform/main.tf.
data "terraform_remote_state" "global" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = "global/terraform.tfstate"
    region = var.aws_region
  }
}
```

- [ ] **Step 3: Write `terraform-web-preview/variables.tf`**

```hcl
variable "preview_name" {
  description = "Short name for this preview environment, e.g. \"proto\". Used as the subdomain (<preview_name>.curry.space) and in every resource name."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,20}$", var.preview_name))
    error_message = "preview_name must be lowercase alphanumeric (with hyphens), starting with a letter, 2-21 characters."
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "state_bucket" {
  description = "Name of the S3 bucket created by ../bootstrap, used to read global/terraform.tfstate. Same account for every stack (D-001)."
  type        = string
}
```

- [ ] **Step 4: Write `terraform-web-preview/locals.tf`**

```hcl
locals {
  name_prefix = "cs-${var.preview_name}-use1"

  # Flat hostname pattern, same as ../terraform/locals.tf: a single
  # *.curry.space wildcard covers this too.
  web_domain = "${var.preview_name}.curry.space"

  cert_arn = data.terraform_remote_state.global.outputs.wildcard_cert_arn
  zone_id  = data.terraform_remote_state.global.outputs.zone_id
}
```

- [ ] **Step 5: Write `terraform-web-preview/environments/proto.tfvars`**

```hcl
preview_name = "proto"

# cs-tfstate-<account-id>, created by ../../bootstrap. Same bucket every
# stack in this account uses (D-001). Account: Curry Labs AI Inc, 670794226662.
state_bucket = "cs-tfstate-670794226662"
```

- [ ] **Step 6: Validate syntax (no backend/credentials needed)**

```bash
cd terraform-web-preview
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.` (Nothing written so far references `waf.tf`/`storage.tf`/`cdn.tf`/`dns.tf`/`outputs.tf`, which don't exist yet, so this should validate cleanly with no errors or warnings.)

- [ ] **Step 7: Format and commit**

```bash
terraform fmt
cd ..
git add terraform-web-preview/main.tf terraform-web-preview/variables.tf terraform-web-preview/locals.tf terraform-web-preview/environments/proto.tfvars
git commit -m "feat(proto-web): root module skeleton for the front-end-only preview stack"
```

---

## Task 2: Logs bucket

**Files:**
- Create: `terraform-web-preview/storage.tf`

**Interfaces:**
- Consumes: `local.name_prefix` (Task 1).
- Produces: `aws_s3_bucket.logs` — consumed by Task 4 (`cdn.tf`).

- [ ] **Step 1: Write `terraform-web-preview/storage.tf`** (identical pattern to `../terraform/storage.tf`)

```hcl
resource "aws_s3_bucket" "logs" {
  bucket = "${local.name_prefix}-logs-${data.aws_caller_identity.current.account_id}"
}

data "aws_caller_identity" "current" {}

# CloudFront standard logging still delivers via the legacy log-delivery
# ACL grant, which requires ACLs to be enabled on the bucket — the one
# place in this config that can't use the modern ownership-enforced
# default.
resource "aws_s3_bucket_ownership_controls" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

resource "aws_s3_bucket_acl" "logs" {
  depends_on = [aws_s3_bucket_ownership_controls.logs]
  bucket     = aws_s3_bucket.logs.id
  acl        = "log-delivery-write"
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = false # log-delivery-write is an AWS-internal ACL grant, not public
  block_public_policy     = true
  ignore_public_acls      = false
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    id     = "expire-90-days"
    status = "Enabled"
    filter {}
    expiration {
      days = 90
    }
  }
}
```

- [ ] **Step 2: Validate**

```bash
cd terraform-web-preview
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Format and commit**

```bash
terraform fmt
cd ..
git add terraform-web-preview/storage.tf
git commit -m "feat(proto-web): CloudFront logs bucket"
```

---

## Task 3: Public WAF ACL

**Files:**
- Create: `terraform-web-preview/waf.tf`

**Interfaces:**
- Consumes: `local.name_prefix` (Task 1).
- Produces: `aws_wafv2_web_acl.public` — consumed by Task 4 (`cdn.tf`).

- [ ] **Step 1: Write `terraform-web-preview/waf.tf`**

```hcl
# Same baseline managed rule groups as every other environment's public
# ACL (../terraform/waf.tf) — the three-rule-group floor from the
# architecture doc, no rate limiting (this is a low-traffic preview
# surface) and no separate admin ACL (there is no admin app here).

locals {
  managed_rule_groups = [
    { name = "AWSManagedRulesAmazonIpReputationList", priority = 10 },
    { name = "AWSManagedRulesCommonRuleSet", priority = 20 },
    { name = "AWSManagedRulesKnownBadInputsRuleSet", priority = 30 },
  ]
}

resource "aws_wafv2_web_acl" "public" {
  name  = "${local.name_prefix}-cf-waf"
  scope = "CLOUDFRONT"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.managed_rule_groups
    content {
      name     = rule.value.name
      priority = rule.value.priority

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          name        = rule.value.name
          vendor_name = "AWS"
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value.name
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-cf-waf"
    sampled_requests_enabled   = true
  }
}
```

- [ ] **Step 2: Validate**

```bash
cd terraform-web-preview
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Format and commit**

```bash
terraform fmt
cd ..
git add terraform-web-preview/waf.tf
git commit -m "feat(proto-web): public WAF ACL"
```

---

## Task 4: CloudFront + S3 (the actual site)

**Files:**
- Create: `terraform-web-preview/cdn.tf`

**Interfaces:**
- Consumes: `local.name_prefix`, `local.web_domain`, `local.cert_arn` (Task 1); `aws_wafv2_web_acl.public` (Task 3); `aws_s3_bucket.logs` (Task 2); `../terraform/modules/cloudfront_spa` (existing, unmodified — takes `name`, `domain_names` (list), `cert_arn`, `web_acl_arn`, `logs_bucket_domain_name`, `logs_prefix`, `enable_noindex`, `tags`).
- Produces: `module.web` with outputs `bucket_name`, `distribution_id`, `distribution_domain_name`, `distribution_hosted_zone_id` — consumed by Tasks 5-6.

- [ ] **Step 1: Write `terraform-web-preview/cdn.tf`**

```hcl
module "web" {
  source = "../terraform/modules/cloudfront_spa"

  name                    = "${local.name_prefix}-web"
  domain_names            = [local.web_domain]
  cert_arn                = local.cert_arn
  web_acl_arn             = aws_wafv2_web_acl.public.arn
  logs_bucket_domain_name = aws_s3_bucket.logs.bucket_domain_name
  logs_prefix             = "cloudfront-web/"
  enable_noindex          = true # preview surface — keep it out of search results

  tags = {
    Component = "web"
    Preview   = var.preview_name
  }
}
```

- [ ] **Step 2: Validate**

```bash
cd terraform-web-preview
terraform init -backend=false -upgrade
terraform validate
```

Expected: `Success! The configuration is valid.` (`-upgrade` re-resolves the local module path now that `cdn.tf` references it.)

- [ ] **Step 3: Format and commit**

```bash
terraform fmt
cd ..
git add terraform-web-preview/cdn.tf
git commit -m "feat(proto-web): CloudFront distribution via the existing cloudfront_spa module"
```

---

## Task 5: DNS records

**Files:**
- Create: `terraform-web-preview/dns.tf`

**Interfaces:**
- Consumes: `local.zone_id`, `local.web_domain` (Task 1); `module.web.distribution_domain_name`, `module.web.distribution_hosted_zone_id` (Task 4).
- Produces: `aws_route53_record.web_a`, `aws_route53_record.web_aaaa`.

- [ ] **Step 1: Write `terraform-web-preview/dns.tf`**

```hcl
resource "aws_route53_record" "web_a" {
  zone_id = local.zone_id
  name    = local.web_domain
  type    = "A"

  alias {
    name                   = module.web.distribution_domain_name
    zone_id                = module.web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "web_aaaa" {
  zone_id = local.zone_id
  name    = local.web_domain
  type    = "AAAA"

  alias {
    name                   = module.web.distribution_domain_name
    zone_id                = module.web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}
```

- [ ] **Step 2: Validate**

```bash
cd terraform-web-preview
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Format and commit**

```bash
terraform fmt
cd ..
git add terraform-web-preview/dns.tf
git commit -m "feat(proto-web): Route 53 alias records for proto.curry.space"
```

---

## Task 6: Outputs

**Files:**
- Create: `terraform-web-preview/outputs.tf`

**Interfaces:**
- Consumes: `module.web.bucket_name`, `module.web.distribution_id` (Task 4); `local.web_domain` (Task 1).
- Produces: `web_bucket_name`, `web_distribution_id`, `web_url` — consumed by Task 12 (rollout: populating `curryspacefe`'s GitHub Environment).

- [ ] **Step 1: Write `terraform-web-preview/outputs.tf`**

```hcl
output "web_bucket_name" {
  value = module.web.bucket_name
}

output "web_distribution_id" {
  value = module.web.distribution_id
}

output "web_url" {
  value = "https://${local.web_domain}"
}
```

- [ ] **Step 2: Full validate of the finished stack**

```bash
cd terraform-web-preview
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Format and commit**

```bash
terraform fmt
cd ..
git add terraform-web-preview/outputs.tf
git commit -m "feat(proto-web): outputs for bucket name, distribution ID, and URL"
```

---

## Task 7: Extend the shared FE-deploy IAM role (additive only)

**Files:**
- Modify: `global/fe-deploy-iam.tf`

**Interfaces:**
- Consumes: `data.aws_caller_identity.current` (already declared in `global/iam.tf`, shared across the `global/` module).
- Produces: `local.fe_preview_bucket_arns`, concatenated into the existing `aws_iam_role_policy.fe_deploy_permissions` resource list.

- [ ] **Step 1: Read the current file to confirm line numbers before editing**

```bash
cat -n global/fe-deploy-iam.tf | sed -n '35,75p'
```

- [ ] **Step 2: Add a second, separate local for preview bucket ARNs — do not touch the existing `fe_bucket_arns` local**

Find this block:
```hcl
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
```

Replace it with:
```hcl
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

  # Front-end-only preview environments (terraform-web-preview/) — web
  # bucket only, no admin app. Add a name here each time a new preview
  # environment is created; see
  # docs/superpowers/specs/2026-09-15-proto-web-preview-design.md.
  fe_preview_bucket_arns = flatten([
    for env in ["proto"] : [
      "arn:aws:s3:::cs-${env}-use1-web-${data.aws_caller_identity.current.account_id}",
      "arn:aws:s3:::cs-${env}-use1-web-${data.aws_caller_identity.current.account_id}/*",
    ]
  ])
}
```

- [ ] **Step 3: Point the policy statement at both lists**

Find:
```hcl
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
```

Replace with:
```hcl
  statement {
    sid    = "SyncStaticSites"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = concat(local.fe_bucket_arns, local.fe_preview_bucket_arns)
  }
```

- [ ] **Step 4: Validate the `global/` module**

```bash
cd global
terraform init -backend=false
terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Format and commit**

```bash
terraform fmt
cd ..
git add global/fe-deploy-iam.tf
git commit -m "feat(proto-web): grant cs-fe-deploy access to the proto preview bucket"
```

---

## Task 8: Add the `proto-web` Terraform workflow target (additive only)

**Files:**
- Modify: `.github/workflows/terraform.yml`
- Modify: `README.md`

**Interfaces:**
- Consumes: existing `vars.STATE_BUCKET`, `vars.AWS_ROLE_ARN` repo variables (unchanged).
- Produces: a new `workflow_dispatch` target `proto-web` that plans/applies `terraform-web-preview/` with `environments/proto.tfvars`, state key `envs/preview-proto/terraform.tfstate`.

- [ ] **Step 1: Read the current workflow file to confirm exact text before editing**

```bash
cat -n .github/workflows/terraform.yml
```

- [ ] **Step 2: Add `proto-web` to the `workflow_dispatch` target choices**

Find:
```yaml
      target:
        description: "Which config to run against"
        required: true
        type: choice
        options: [bootstrap, global, beta, staging, production]
```

Replace with:
```yaml
      target:
        description: "Which config to run against"
        required: true
        type: choice
        options: [bootstrap, global, beta, staging, production, proto-web]
```

- [ ] **Step 3: Guard the existing generic "environment" steps against the new target**

There are three steps in the `run` job with this condition — `Init (environment)`, `Plan (environment)`, `Apply (environment)`. Find each:

```yaml
      - name: Init (environment)
        if: inputs.target != 'global' && inputs.target != 'bootstrap'
```
```yaml
      - name: Plan (environment)
        if: inputs.target != 'global' && inputs.target != 'bootstrap'
```
```yaml
      - name: Apply (environment)
        if: inputs.target != 'global' && inputs.target != 'bootstrap' && inputs.action == 'apply'
```

Replace each `if:` line, adding one clause (order of the other clauses unchanged, so this is a pure addition — `beta`/`staging`/`production`'s truth value for these conditions doesn't change):
```yaml
        if: inputs.target != 'global' && inputs.target != 'bootstrap' && inputs.target != 'proto-web'
```
```yaml
        if: inputs.target != 'global' && inputs.target != 'bootstrap' && inputs.target != 'proto-web'
```
```yaml
        if: inputs.target != 'global' && inputs.target != 'bootstrap' && inputs.target != 'proto-web' && inputs.action == 'apply'
```

- [ ] **Step 4: Add new `proto-web`-specific steps, right after the "Apply (environment)" step**

Find the end of the `Apply (environment)` step (the last step in the file) and append after it:

```yaml
      - name: Init (proto-web)
        if: inputs.target == 'proto-web'
        working-directory: terraform-web-preview
        run: |
          terraform init \
            -backend-config="bucket=${{ vars.STATE_BUCKET }}" \
            -backend-config="key=envs/preview-proto/terraform.tfstate" \
            -backend-config="region=${{ env.AWS_REGION }}" \
            -backend-config="dynamodb_table=cs-tfstate-lock"

      - name: Plan (proto-web)
        if: inputs.target == 'proto-web'
        working-directory: terraform-web-preview
        run: terraform plan -var-file=environments/proto.tfvars -out=tfplan

      - name: Apply (proto-web)
        if: inputs.target == 'proto-web' && inputs.action == 'apply'
        working-directory: terraform-web-preview
        run: terraform apply tfplan

      - name: Show outputs (proto-web)
        if: inputs.target == 'proto-web' && inputs.action == 'apply'
        working-directory: terraform-web-preview
        run: terraform output
```

- [ ] **Step 5: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/terraform.yml')); print('OK')"
```

Expected: `OK`

- [ ] **Step 6: Update `README.md`'s Layout section**

Find:
```
terraform/environments/*.tfvars     Per-environment variable values.
```

Replace with:
```
terraform/environments/*.tfvars     Per-environment variable values.
terraform-web-preview/  Front-end-only preview environments (no VPC/ECS/Aurora/Redis/ALB):
                         S3 + CloudFront + WAF + DNS only, via the same cloudfront_spa
                         module terraform/ uses. One tfvars file per preview environment
                         (currently just proto.tfvars). Applied via the terraform.yml
                         workflow's `proto-web` target (own state file, separate from
                         terraform/'s beta/staging/production state).
```

- [ ] **Step 7: Add a verification snippet, next to the existing "Verifying beta" section**

Find:
```
## Verifying beta
```

Replace with:
```
## Verifying proto

```bash
curl -I https://proto.curry.space   # expect a CloudFront/S3 response, not a cert error
```

## Verifying beta
```

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/terraform.yml README.md
git commit -m "feat(proto-web): add proto-web Terraform workflow target and docs"
```

---

## Task 9: Open the `curry-space-infra` PR

**Files:** none (repo operation)

- [ ] **Step 1: Push the branch**

```bash
git push -u origin feat/proto-web-preview
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create --repo Curry-Studio/curry-space-infra \
  --base main --head feat/proto-web-preview \
  --title "Add proto.curry.space front-end-only preview environment" \
  --body "Implements docs/superpowers/specs/2026-09-15-proto-web-preview-design.md.

New, isolated terraform-web-preview/ stack (own state file) for proto.curry.space — S3 + CloudFront + WAF + DNS only, no backend. Two small additive edits to shared files: global/fe-deploy-iam.tf (adds the proto bucket to cs-fe-deploy's existing policy) and .github/workflows/terraform.yml (adds a proto-web target; existing beta/staging/production/global/bootstrap steps are unchanged — see the design doc's Safety table).

Does not touch terraform/, curryspacebe, or any beta/staging/production resource.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 3: Confirm the PR's automatic `plan-on-pr` check ran for the `global` target and shows only the expected single-resource diff**

```bash
gh pr checks --repo Curry-Studio/curry-space-infra feat/proto-web-preview
```

Then open the `plan-on-pr (global)` run's log and confirm the plan shows exactly one resource changing in place: `aws_iam_role_policy.fe_deploy_permissions`. (`terraform-web-preview/` is not part of `plan-on-pr`'s matrix by design — it's validated manually via the `proto-web` target in Task 11.)

- [ ] **Step 4: STOP — get explicit user confirmation before merging.** This PR touches a file (`global/fe-deploy-iam.tf`) shared with beta/staging/production's deploy pipeline. Do not merge without the user reviewing the plan output from Step 3.

---

## Task 10: `curryspacefe` — add `proto` to the deploy trigger

**Files:**
- Modify (in the `curryspacefe` repo): `.github/workflows/deploy.yml`

**Interfaces:**
- Consumes: nothing new.
- Produces: `proto` becomes a valid `push` trigger branch, resolving to a GitHub Environment named `proto` (created in Task 12).

- [ ] **Step 1: Branch off `main` in `curryspacefe`**

```bash
cd /Users/prajwalvb/slam-internal/curryspacefe
git fetch origin
git checkout -b feat/proto-deploy-trigger origin/main
```

- [ ] **Step 2: Edit the branch trigger — the only change in this file**

Find:
```yaml
on:
  push:
    branches: [beta, staging, main]
  workflow_dispatch:
```

Replace with:
```yaml
on:
  push:
    branches: [beta, staging, main, proto]
  workflow_dispatch:
```

- [ ] **Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/deploy.yml')); print('OK')"
```

Expected: `OK`

- [ ] **Step 4: Commit and push**

```bash
git add .github/workflows/deploy.yml
git commit -m "feat: deploy the proto branch to the proto environment

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
git push -u origin feat/proto-deploy-trigger
```

- [ ] **Step 5: Open the PR**

```bash
gh pr create --repo Curry-Studio/curryspacefe \
  --base main --head feat/proto-deploy-trigger \
  --title "Deploy the proto branch to proto.curry.space" \
  --body "Adds proto to deploy.yml's push trigger, matching beta/staging/main. Requires a proto GitHub Environment (S3_BUCKET, CF_DISTRIBUTION_ID, AWS_ROLE_ARN) to exist before a push to proto succeeds — see curry-space-infra's proto-web-preview design doc.

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
```

- [ ] **Step 6: STOP — do not merge yet.** Merging now would make the next push to `proto` fail (no GitHub Environment variables exist yet). Wait until Task 13 is done.

---

## Task 11: Rollout — apply `global` (additive IAM change)

**Files:** none (this is the actual infrastructure change — the first real AWS mutation in this plan)

- [ ] **Step 1: STOP — confirm with the user before running anything in this task.** This is the first step that touches real, shared AWS state.

- [ ] **Step 2: Merge the `curry-space-infra` PR from Task 9** (only after the user has reviewed the plan-on-pr diff and explicitly approves the merge)

```bash
gh pr merge --repo Curry-Studio/curry-space-infra feat/proto-web-preview --squash
```

- [ ] **Step 3: Run `global` plan via the existing workflow**

```bash
gh workflow run terraform.yml --repo Curry-Studio/curry-space-infra -f target=global -f action=plan
gh run watch --repo Curry-Studio/curry-space-infra
```

- [ ] **Step 4: Read the plan output and confirm it shows exactly one resource changing in place**

```bash
gh run view --repo Curry-Studio/curry-space-infra --log | grep -A5 "Plan (global)"
```

Expected: `~ update in-place` for `aws_iam_role_policy.fe_deploy_permissions` only — `1 to add, 1 to change, 0 to destroy` (the `1 to add` is the `local.fe_preview_bucket_arns` local having no separate resource of its own — confirm the actual line count in the plan matches "1 to change, 0 to destroy" for real infrastructure resources). Nothing else in `global/` (ACM cert, DNS zone, ECR, media buckets, security services, `cs-be-deploy`, `cs-infra-deploy`) should show any change.

- [ ] **Step 5: STOP — show this diff to the user and get explicit confirmation before applying.**

- [ ] **Step 6: Apply**

```bash
gh workflow run terraform.yml --repo Curry-Studio/curry-space-infra -f target=global -f action=apply
gh run watch --repo Curry-Studio/curry-space-infra
```

Expected: workflow succeeds (the `global` GitHub Environment may require a manual approval click, per the repo's README — if so, tell the user to approve it in the Actions UI).

---

## Task 12: Rollout — apply `proto-web` (creates the actual preview site)

**Files:** none (infrastructure change)

- [ ] **Step 1: STOP — confirm with the user before running.**

- [ ] **Step 2: Plan**

```bash
gh workflow run terraform.yml --repo Curry-Studio/curry-space-infra -f target=proto-web -f action=plan
gh run watch --repo Curry-Studio/curry-space-infra
```

- [ ] **Step 3: Read the plan and confirm it only creates resources inside `terraform-web-preview/`'s own state — an S3 bucket (+ related sub-resources), a CloudFront distribution, a WAF Web ACL, and two Route 53 records. Nothing in `terraform/`'s beta/staging/production state should appear (it's a different state file entirely, so it structurally can't).**

```bash
gh run view --repo Curry-Studio/curry-space-infra --log | grep -A3 "Plan (proto-web)"
```

- [ ] **Step 4: STOP — show this diff to the user and get explicit confirmation before applying.**

- [ ] **Step 5: Apply**

```bash
gh workflow run terraform.yml --repo Curry-Studio/curry-space-infra -f target=proto-web -f action=apply
gh run watch --repo Curry-Studio/curry-space-infra
```

- [ ] **Step 6: Capture the outputs for Task 13**

```bash
gh run view --repo Curry-Studio/curry-space-infra --log | grep -A5 "Show outputs (proto-web)"
```

Note down `web_bucket_name` and `web_distribution_id` — needed in Task 13.

---

## Task 13: Create the `proto` GitHub Environment in `curryspacefe` (scripted, no manual AWS console work)

**Files:** none (GitHub repo configuration, via `gh` CLI)

**Interfaces:**
- Consumes: `web_bucket_name`, `web_distribution_id` (Task 12 outputs); the existing `AWS_ROLE_ARN` value already set on `curryspacefe`'s `beta` GitHub Environment.

- [ ] **Step 1: Create the `proto` environment**

```bash
gh api --method PUT repos/Curry-Studio/curryspacefe/environments/proto
```

- [ ] **Step 2: Read beta's existing shared variables to copy forward**

```bash
gh variable list --repo Curry-Studio/curryspacefe --env beta
```

Note the values of `AWS_ROLE_ARN`, and — if the user wants proto to point at the same backing services as beta — `CORS_PROXY_URL`, `FIREBASE_API_KEY`, `FIREBASE_AUTH_DOMAIN`, `FIREBASE_PROJECT_ID`, `FIREBASE_APP_ID`. Confirm with the user whether proto should share these or go unset (matching the existing behavior for any environment where they're not set — see the `CORS_SETUP.md`-referencing comment in `deploy.yml`).

- [ ] **Step 3: Set proto's environment variables**

```bash
gh variable set AWS_ROLE_ARN --repo Curry-Studio/curryspacefe --env proto --body "<value copied from beta in Step 2>"
gh variable set S3_BUCKET --repo Curry-Studio/curryspacefe --env proto --body "<web_bucket_name from Task 12>"
gh variable set CF_DISTRIBUTION_ID --repo Curry-Studio/curryspacefe --env proto --body "<web_distribution_id from Task 12>"
```

If the user confirmed sharing beta's CORS/Firebase config in Step 2, also:
```bash
gh variable set CORS_PROXY_URL --repo Curry-Studio/curryspacefe --env proto --body "<value from beta>"
gh variable set FIREBASE_API_KEY --repo Curry-Studio/curryspacefe --env proto --body "<value from beta>"
gh variable set FIREBASE_AUTH_DOMAIN --repo Curry-Studio/curryspacefe --env proto --body "<value from beta>"
gh variable set FIREBASE_PROJECT_ID --repo Curry-Studio/curryspacefe --env proto --body "<value from beta>"
gh variable set FIREBASE_APP_ID --repo Curry-Studio/curryspacefe --env proto --body "<value from beta>"
```

- [ ] **Step 4: Verify**

```bash
gh variable list --repo Curry-Studio/curryspacefe --env proto
```

Expected: `AWS_ROLE_ARN`, `S3_BUCKET`, `CF_DISTRIBUTION_ID` (and optionally the CORS/Firebase vars) all present with the expected values.

---

## Task 14: Rollout — land the deploy trigger on `main` and `proto`, then verify

**Files:** none (repo operations + live verification)

- [ ] **Step 1: STOP — confirm with the user before merging or pushing to shared branches.**

- [ ] **Step 2: Merge the `curryspacefe` PR from Task 10 into `main`**

```bash
gh pr merge --repo Curry-Studio/curryspacefe feat/proto-deploy-trigger --squash
```

- [ ] **Step 3: Land the same one-line change on the `proto` branch itself** — required because GitHub reads a `push`-triggered workflow's definition from the ref being pushed, not from `main`; `proto`'s own copy of `deploy.yml` still lacks `proto` in its branch list otherwise.

```bash
cd /Users/prajwalvb/slam-internal/curryspacefe
git fetch origin
git checkout proto
git pull origin proto
git cherry-pick <commit-sha-from-feat/proto-deploy-trigger>
```

- [ ] **Step 4: STOP — confirm with the user before pushing directly to `proto`** (a shared branch, outward-facing: this push triggers the first real deploy).

```bash
git push origin proto
```

- [ ] **Step 5: Watch the deploy**

```bash
gh run watch --repo Curry-Studio/curryspacefe
```

- [ ] **Step 6: Verify proto.curry.space serves the build**

```bash
curl -I https://proto.curry.space
```

Expected: a CloudFront/S3 response (e.g. `HTTP/2 200`), not a cert or DNS error.

- [ ] **Step 7: Verify beta is completely unaffected**

```bash
curl -I https://beta.curry.space
curl -I https://beta.curry.space/api/healthz
```

Expected: identical responses to before this plan started — a CloudFront/S3 response from the first, `200` from the ALB fixed-response rule on the second.
