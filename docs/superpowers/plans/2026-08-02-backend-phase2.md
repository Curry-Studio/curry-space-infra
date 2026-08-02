# Backend Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add VPC, ALB, ECS (API/worker/scheduler), Aurora + RDS Proxy, Redis, ECR, Secrets Manager, and account-wide security services to `curry-space-infra`, sized and wired exactly per the architecture doc and `docs/superpowers/specs/2026-08-02-backend-phase2-design.md`, applied to beta only.

**Architecture:** Most of this extends the existing `terraform/` root module (same per-environment state as phase 1's S3/CloudFront/WAF). Each task adds one or two `.tf` files and validates cleanly via `terraform plan` before the next task starts; nothing is actually created in AWS until the final "apply and verify" task. Three things are account-wide, not per-environment, and go in `global/` instead: the ECR repository, the two media buckets, and the security services (CloudTrail, Config, GuardDuty, Security Hub) — see the D-008 constraint below for why.

**Tech Stack:** Terraform ~> 1.9, AWS provider ~> 5.0, existing `modules/cloudfront_spa` (phase 1), new `modules/ecs_service`.

## Global Constraints

- Single AWS account across beta/staging/production (decisions.md D-001) — account ID `670794226662`, region `us-east-1` throughout.
- Naming convention: `cs-<env>-use1-<component>-<resource-type>` (architecture doc §2.4), matching phase 1's `local.name_prefix = "cs-${var.environment}-use1"` already in `terraform/locals.tf`.
- VPC CIDRs: beta `10.10.0.0/16`, staging `10.20.0.0/16`, production `10.0.0.0/16` (architecture doc §3.1) — non-overlapping so future peering doesn't force a rebuild.
- Beta sizing is exact per architecture doc §17.2 — no further shrinking: 1 task per service, 0.5 vCPU/1 GB, no auto scaling, `db.t4g.medium` Aurora, `cache.t4g.small` Redis, 1 NAT gateway, 2 AZs.
- No real backend application image exists yet. ECS services are expected to show 0 healthy tasks after apply — this is the expected end state for this plan, not a bug to chase.
- `beta`/`staging`/`production` Terraform applies use the existing admin `Github` IAM role for this phase (not `cs-infra-deploy`), since ECS task role creation needs `iam:CreateRole`/`iam:PassRole`.
- Staging and production `.tfvars` get every new variable added in this plan, with their architecture-doc-specified values, but are **never applied** in this plan — only beta is applied (final task).
- Every new resource gets `Environment = var.environment` via the existing `default_tags` block in `terraform/main.tf` — no per-resource tagging needed.
- Media storage is two shared S3 buckets, not one per environment (decisions.md D-008): `cs-nonprod-use1-media` (beta and staging both use this one) and `cs-prod-use1-media`. Same reasoning applies to the ECR repository (`cs/app`) — one, shared by every environment. Both live in `global/`, referenced from `terraform/` as literal, deterministic strings rather than `terraform_remote_state` lookups.

---

## Task 1: Networking — VPC, subnets, NAT, security groups

**Files:**
- Create: `terraform/networking.tf`
- Modify: `terraform/variables.tf` (add `vpc_cidr`)
- Modify: `terraform/locals.tf` (add subnet CIDR computation)
- Modify: `terraform/environments/beta.tfvars`, `staging.tfvars`, `production.tfvars` (add `vpc_cidr`)

**Interfaces:**
- Produces: `aws_vpc.this` (id via `aws_vpc.this.id`), `aws_subnet.public[*]`, `aws_subnet.app[*]`, `aws_subnet.data[*]` (each a list keyed by AZ index), `aws_security_group.alb.id`, `.api.id`, `.worker.id`, `.scheduler.id`, `.rds_proxy.id`, `.aurora.id`, `.redis.id`. `var.az_count` (2 for beta/staging, 3 for production) — later tasks use the variable directly, not a local. `local.availability_zones` (list of AZ names actually used).

- [ ] **Step 1: Add `vpc_cidr` variable and per-environment values**

In `terraform/variables.tf`, add:

```hcl
variable "vpc_cidr" {
  description = "VPC CIDR block. Beta 10.10.0.0/16, staging 10.20.0.0/16, production 10.0.0.0/16 — non-overlapping across environments (architecture doc §3.1)."
  type        = string
}

variable "az_count" {
  description = "Number of AZs to spread subnets across. 2 for beta/staging, 3 for production."
  type        = number
  default     = 2
}
```

Append to `terraform/environments/beta.tfvars`:

```hcl
vpc_cidr = "10.10.0.0/16"
az_count = 2
```

Append to `terraform/environments/staging.tfvars`:

```hcl
vpc_cidr = "10.20.0.0/16"
az_count = 2
```

Append to `terraform/environments/production.tfvars`:

```hcl
vpc_cidr = "10.0.0.0/16"
az_count = 3
```

- [ ] **Step 2: Add subnet-tier locals**

In `terraform/locals.tf`, add inside the existing `locals` block (don't create a second `locals` block — merge into the one already there):

```hcl
  availability_zones = slice(["us-east-1a", "us-east-1b", "us-east-1c"], 0, var.az_count)

  # /20 blocks carved out of the environment's /16: index 0-2 public,
  # 3-5 app, 6-8 data. cidrsubnet() means the same logic produces the
  # right layout for any of the three environments' CIDRs without
  # hardcoding a subnet table per environment (architecture doc §3.2).
  public_subnet_cidrs = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i)]
  app_subnet_cidrs     = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 3)]
  data_subnet_cidrs    = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 6)]
```

- [ ] **Step 3: Write `terraform/networking.tf`**

```hcl
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
  tags        = { Name = "${local.name_prefix}-sg-alb" }
  # No inline ingress/egress blocks — every rule is a standalone
  # aws_security_group_rule below. Mixing inline blocks with standalone
  # rule resources on the same security group is a documented Terraform/
  # AWS-provider conflict (the two mechanisms fight over which rules exist).
}

resource "aws_security_group_rule" "cloudfront_to_alb" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  security_group_id = aws_security_group.alb.id
  prefix_list_ids   = [data.aws_ec2_managed_prefix_list.cloudfront.id]
  description       = "HTTPS from CloudFront only — not the open internet"
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
  description               = "From the ALB"
}

resource "aws_security_group_rule" "alb_egress_to_api" {
  type                     = "egress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  security_group_id        = aws_security_group.alb.id
  source_security_group_id = aws_security_group.api.id
  description               = "To API tasks"
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

# Egress halves of the three rules above. api/worker/scheduler have zero
# inline blocks on their own security groups (bare resources, rules added
# only as standalone aws_security_group_rules) — Terraform revokes AWS's
# default allow-all egress on a bare security group, so without these,
# none of the three can actually send traffic to RDS Proxy at all.
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

# Egress halves of the three rules above — same reasoning as the RDS Proxy
# egress rules: without these, api/worker/scheduler cannot send traffic to
# Redis at all, since none of the three has any other egress rule covering
# port 6379.
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
```

- [ ] **Step 4: Format, validate, and plan**

```bash
cd terraform
terraform fmt .
terraform init \
  -backend-config="bucket=cs-tfstate-670794226662" \
  -backend-config="key=envs/beta/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=cs-tfstate-lock"
terraform validate
terraform plan -var-file=environments/beta.tfvars
```

Expected: `terraform validate` prints `Success!`. `terraform plan` shows `Plan: 30 to add` (roughly — 1 VPC, 1 IGW, 6 subnets, 1 EIP, 1 NAT gateway, 4 route tables, 5 route table associations, 1 S3 endpoint, 4 interface endpoints, 1 VPC endpoint SG, 7 security groups, 10 security group rules), `0 to change, 0 to destroy`. No errors. Do not apply yet — later tasks add more to the same plan.

- [ ] **Step 5: Commit**

```bash
git add terraform/networking.tf terraform/variables.tf terraform/locals.tf terraform/environments/*.tfvars
git commit -m "Add VPC, subnets, NAT, and security groups for backend phase 2"
git push
```

---

## Task 2: Shared resources in `global/` — ECR repository and media buckets

**Files:**
- Create: `global/ecr.tf`, `global/media.tf`

**Interfaces:**
- Produces nothing other tasks reference via Terraform state — Task 7 constructs the ECR image URI and the media bucket ARNs as literal strings (both are fully deterministic: `<account-id>.dkr.ecr.us-east-1.amazonaws.com/cs/app:<tag>` and `arn:aws:s3:::cs-<tier>-use1-media`), not via `terraform_remote_state`. This task only needs to have been **applied** before Task 11's final apply, not referenced at plan time.
- These are account-wide, not per-environment (decisions.md D-008) — that's why they're in `global/`. Putting either in the per-environment `terraform/` would mean staging's future apply collides with beta's over an identically-named resource, since S3 bucket names and ECR repository names are globally unique, not scoped per Terraform state.

- [ ] **Step 1: Write `global/ecr.tf`**

```hcl
# One repository for API, worker, scheduler, and the migration task — they
# share one image and differ only by ECS command (architecture doc §14.7).
# Shared by every environment (decisions.md D-008); only the image tag
# differs between a beta deploy and a production one.
resource "aws_ecr_repository" "app" {
  name                 = "cs/app"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep the newest 30 sha-tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 30
        }
        action = { type = "expire" }
      }
    ]
  })
}
```

- [ ] **Step 2: Write `global/media.tf`**

```hcl
# Two buckets total — nonprod (beta and staging share this one) and prod.
# No further subdivision (decisions.md D-008). Bucket names don't need an
# account-id suffix for uniqueness the way the state bucket does, since
# "cs-nonprod-use1-media" and "cs-prod-use1-media" are specific enough
# that a collision with an unrelated AWS customer's bucket is vanishingly
# unlikely — but if `terraform apply` fails with BucketAlreadyExists,
# that's the reason, and appending the account ID is the fix.

resource "aws_s3_bucket" "media" {
  for_each = toset(["nonprod", "prod"])
  bucket   = "cs-${each.value}-use1-media"
}

resource "aws_s3_bucket_versioning" "media" {
  for_each = aws_s3_bucket.media
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  for_each = aws_s3_bucket.media
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  for_each                = aws_s3_bucket.media
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

- [ ] **Step 3: Validate and plan**

```bash
cd global
terraform fmt .
terraform init \
  -backend-config="bucket=cs-tfstate-670794226662" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=cs-tfstate-lock"
terraform validate
terraform plan
```

Expected: `Success!`. Plan adds 2 resources for ECR (`aws_ecr_repository.app`, `aws_ecr_lifecycle_policy.app`) and 8 for media (2 buckets × 4 resources each via `for_each`). No changes to the existing ACM cert, Route 53 lookup, or either IAM deploy role already in `global/`.

- [ ] **Step 4: Apply**

```bash
terraform apply
```

Safe to apply directly — additive, account-wide, doesn't touch beta/staging/production resources. Confirm the plan output matches Step 3 before typing `yes`.

- [ ] **Step 5: Commit**

```bash
git add global/ecr.tf global/media.tf
git commit -m "Add shared ECR repository and nonprod/prod media buckets to global/"
git push
```

---

## Task 3: Secrets Manager containers

**Files:**
- Create: `terraform/secrets.tf`

**Interfaces:**
- Produces: `aws_secretsmanager_secret.db_master.arn`, `.db_app.arn`, `.redis_auth.arn`, `.alb_origin_verify.arn`, `.jwt.arn`. Also `random_password.db_master.result`, `.db_app.result`, `.redis_auth.result`, `.alb_origin_verify.result` — consumed by Task 4 (Aurora), Task 5 (Redis), and Task 6 (ALB listener rule).

- [ ] **Step 1: Write `terraform/secrets.tf`**

```hcl
# Random values generated by Terraform for infra-level credentials.
# cs/<env>/jwt is deliberately NOT generated here — a signing key nobody's
# tracked the rotation of is worse than an empty secret waiting for a real
# one (spec: docs/superpowers/specs/2026-08-02-backend-phase2-design.md).

resource "random_password" "db_master" {
  length  = 32
  special = false # Aurora master password disallows some special characters
}

resource "aws_secretsmanager_secret" "db_master" {
  name = "cs/${var.environment}/db/master"
}

resource "aws_secretsmanager_secret_version" "db_master" {
  secret_id     = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({ username = "dbadmin", password = random_password.db_master.result })
}

resource "random_password" "db_app" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "db_app" {
  name = "cs/${var.environment}/db/app"
}

resource "aws_secretsmanager_secret_version" "db_app" {
  secret_id     = aws_secretsmanager_secret.db_app.id
  secret_string = jsonencode({ username = "cs_app", password = random_password.db_app.result })
}

resource "random_password" "redis_auth" {
  length  = 32
  special = false # Redis AUTH tokens disallow some special characters too
}

resource "aws_secretsmanager_secret" "redis_auth" {
  name = "cs/${var.environment}/redis/auth"
}

resource "aws_secretsmanager_secret_version" "redis_auth" {
  secret_id     = aws_secretsmanager_secret.redis_auth.id
  secret_string = random_password.redis_auth.result
}

resource "random_password" "alb_origin_verify" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "alb_origin_verify" {
  name = "cs/${var.environment}/alb/origin-verify"
}

resource "aws_secretsmanager_secret_version" "alb_origin_verify" {
  secret_id     = aws_secretsmanager_secret.alb_origin_verify.id
  secret_string = random_password.alb_origin_verify.result
}

# Empty on purpose — fill in manually once the backend app exists and a
# real signing key is generated and tracked.
resource "aws_secretsmanager_secret" "jwt" {
  name = "cs/${var.environment}/jwt"
}
```

- [ ] **Step 2: Validate and plan**

```bash
cd terraform
terraform fmt .
terraform validate
terraform plan -var-file=environments/beta.tfvars
```

Expected: `Success!`. Plan adds 9 resources (4 `random_password`, 5 `aws_secretsmanager_secret` + 4 `aws_secretsmanager_secret_version` — 9 total: recount is 4 random_password + 5 secrets + 4 versions = 13; state the actual number from your plan output rather than assuming, but confirm no errors and no destructive changes to Task 1/2 resources).

- [ ] **Step 3: Commit**

```bash
git add terraform/secrets.tf
git commit -m "Add Secrets Manager containers for DB, Redis, and ALB origin-verify credentials"
git push
```

---

## Task 4: Aurora PostgreSQL + RDS Proxy

**Files:**
- Create: `terraform/database.tf`
- Modify: `terraform/variables.tf` (add `aurora_instance_class`, `aurora_instance_count`, `aurora_backup_retention_days`)
- Modify: `terraform/environments/beta.tfvars`, `staging.tfvars`, `production.tfvars`

**Interfaces:**
- Consumes: `aws_subnet.data[*].id`, `aws_security_group.aurora.id`, `aws_security_group.rds_proxy.id` (Task 1); `random_password.db_master/.db_app.result`, `aws_secretsmanager_secret.db_app.arn` (Task 3).
- Produces: `aws_rds_cluster.this.endpoint` (writer), `aws_db_proxy.this.endpoint` — consumed by Task 7's task definitions as the `DATABASE_URL`/proxy host env var.

- [ ] **Step 1: Add Aurora variables**

In `terraform/variables.tf`:

```hcl
variable "aurora_instance_class" {
  description = "db.t4g.medium (beta), db.t4g.large (staging), db.r7g.large (production) — architecture doc §17.2-17.4."
  type        = string
}

variable "aurora_instance_count" {
  description = "1 = writer only (beta, staging). 2 = writer + 1 reader (production)."
  type        = number
  default     = 1
}

variable "aurora_backup_retention_days" {
  type = number
}
```

Append to `beta.tfvars`:

```hcl
aurora_instance_class        = "db.t4g.medium"
aurora_instance_count        = 1
aurora_backup_retention_days = 1
```

Append to `staging.tfvars`:

```hcl
aurora_instance_class        = "db.t4g.large"
aurora_instance_count        = 1
aurora_backup_retention_days = 7
```

Append to `production.tfvars`:

```hcl
aurora_instance_class        = "db.r7g.large"
aurora_instance_count        = 2
aurora_backup_retention_days = 35
```

- [ ] **Step 2: Write `terraform/database.tf`**

```hcl
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
  count                        = var.aurora_instance_count
  identifier                   = "${local.name_prefix}-aurora-${count.index}"
  cluster_identifier           = aws_rds_cluster.this.id
  instance_class                = var.aurora_instance_class
  engine                        = aws_rds_cluster.this.engine
  engine_version                = aws_rds_cluster.this.engine_version
  db_subnet_group_name          = aws_db_subnet_group.this.name
  # Performance Insights isn't supported on t4g classes (production uses
  # r7g and is the only environment that gets it — architecture doc §12.1).
  performance_insights_enabled = var.environment == "production"
  # AWS rejects a non-zero monitoring_interval without a matching
  # monitoring_role_arn (InvalidParameterCombination) — terraform validate
  # doesn't catch this, only a real apply does. Both must be conditional
  # together, not just the role.
  monitoring_interval = var.environment == "production" ? 60 : 0
  monitoring_role_arn = var.environment == "production" ? aws_iam_role.rds_enhanced_monitoring[0].arn : null
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
```

- [ ] **Step 3: Validate and plan**

```bash
cd terraform
terraform fmt .
terraform validate
terraform plan -var-file=environments/beta.tfvars
```

Expected: `Success!` from validate. Plan adds the subnet group, parameter group, cluster, 1 cluster instance (beta's `aurora_instance_count = 1`), the RDS Proxy role/policy, proxy, default target group, and target — roughly 9 resources. `aws_iam_role.rds_enhanced_monitoring` and its policy attachment show as not created for beta (count = 0, production only).

- [ ] **Step 4: Commit**

```bash
git add terraform/database.tf terraform/variables.tf terraform/environments/*.tfvars
git commit -m "Add Aurora PostgreSQL cluster and RDS Proxy"
git push
```

---

## Task 5: ElastiCache Redis

**Files:**
- Create: `terraform/redis.tf`
- Modify: `terraform/variables.tf` (add `redis_node_type`, `redis_replica_count`)
- Modify: `terraform/environments/beta.tfvars`, `staging.tfvars`, `production.tfvars`

**Interfaces:**
- Consumes: `aws_subnet.data[*].id`, `aws_security_group.redis.id` (Task 1); `random_password.redis_auth.result` (Task 3).
- Produces: `aws_elasticache_replication_group.this.primary_endpoint_address` — consumed by Task 7's task definitions.

- [ ] **Step 1: Add Redis variables**

In `terraform/variables.tf`:

```hcl
variable "redis_node_type" {
  description = "cache.t4g.small (beta), cache.t4g.medium (staging), cache.r7g.large (production) — architecture doc §11.1."
  type        = string
}

variable "redis_replica_count" {
  description = "0 = single node (beta). 1 = primary + replica, Multi-AZ (staging, production)."
  type        = number
  default     = 0
}
```

Append to `beta.tfvars`:

```hcl
redis_node_type     = "cache.t4g.small"
redis_replica_count = 0
```

Append to `staging.tfvars`:

```hcl
redis_node_type     = "cache.t4g.medium"
redis_replica_count = 1
```

Append to `production.tfvars`:

```hcl
redis_node_type     = "cache.r7g.large"
redis_replica_count = 1
```

- [ ] **Step 2: Write `terraform/redis.tf`**

```hcl
resource "aws_elasticache_subnet_group" "this" {
  name       = "${local.name_prefix}-redis"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_elasticache_parameter_group" "this" {
  name   = "${local.name_prefix}-redis-pg"
  family = "redis7"

  # volatile-lru only evicts keys with an explicit TTL. BullMQ job keys
  # have no TTL, so under allkeys-lru they'd be evicted under memory
  # pressure and queued work would silently disappear (architecture doc
  # §11.1 — this is called out as the single most important Redis setting).
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${local.name_prefix}-redis"
  description           = "Curry Space ${var.environment} — cache, sessions, BullMQ"
  engine                 = "redis"
  engine_version         = "7.1"
  node_type              = var.redis_node_type
  num_cache_clusters     = 1 + var.redis_replica_count
  automatic_failover_enabled = var.redis_replica_count > 0
  multi_az_enabled          = var.redis_replica_count > 0
  subnet_group_name         = aws_elasticache_subnet_group.this.name
  security_group_ids        = [aws_security_group.redis.id]
  parameter_group_name       = aws_elasticache_parameter_group.this.name
  at_rest_encryption_enabled = true
  transit_encryption_enabled = true
  auth_token                 = random_password.redis_auth.result
  snapshot_retention_limit   = var.environment == "production" ? 7 : 0
  snapshot_window            = "08:00-09:00"
}
```

- [ ] **Step 3: Validate and plan**

```bash
cd terraform
terraform fmt .
terraform validate
terraform plan -var-file=environments/beta.tfvars
```

Expected: `Success!`. Plan adds 4 resources (subnet group, parameter group, replication group — `num_cache_clusters = 1` for beta since `redis_replica_count = 0`). No changes to earlier tasks' resources.

- [ ] **Step 4: Commit**

```bash
git add terraform/redis.tf terraform/variables.tf terraform/environments/*.tfvars
git commit -m "Add ElastiCache Redis replication group"
git push
```

---

## Task 6: Application Load Balancer

**Files:**
- Create: `terraform/alb.tf`

**Interfaces:**
- Consumes: `aws_subnet.public[*].id`, `aws_security_group.alb.id` (Task 1); `local.cert_arn` (already exists in `terraform/locals.tf` from phase 1 — the same wildcard cert covers the ALB since it's in `us-east-1` too, no new cert needed); `random_password.alb_origin_verify.result` (Task 3).
- Produces: `aws_lb.this.dns_name`, `.zone_id` (consumed by Task 8's CloudFront origin), `aws_lb_target_group.api.arn` (consumed by Task 7's API service).

**Note on `X-Origin-Verify`:** the security group prefix-list restriction (Task 1) blocks anyone outside CloudFront's IP range, but that range is shared across every CloudFront customer — another distribution could in principle point at this ALB's hostname and pass the security-group check. The header is what proves a request came through *this* distribution specifically, so it must gate every rule, including the health check — not just the catch-all forward.

- [ ] **Step 1: Write `terraform/alb.tf`**

```hcl
resource "aws_lb" "this" {
  name               = "${local.name_prefix}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id
  idle_timeout       = 60

  tags = { Name = "${local.name_prefix}-alb" }
}

resource "aws_lb_target_group" "api" {
  name        = "${local.name_prefix}-api-tg"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"

  health_check {
    path                = "/healthz"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  deregistration_delay = 30
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port               = 80
  protocol           = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port               = 443
  protocol           = "HTTPS"
  ssl_policy         = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn    = local.cert_arn

  # No rule matches without the correct X-Origin-Verify header (see rules
  # below), so anything that reaches here despite the security group
  # (e.g. another CloudFront customer's distribution, sharing the same
  # origin-facing IP range) gets rejected rather than silently forwarded.
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }
}

resource "aws_lb_listener_rule" "health" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "OK"
      status_code  = "200"
    }
  }

  condition {
    path_pattern { values = ["/healthz"] }
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values            = [random_password.alb_origin_verify.result]
    }
  }
}

resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }

  condition {
    path_pattern { values = ["/*"] }
  }

  condition {
    http_header {
      http_header_name = "X-Origin-Verify"
      values            = [random_password.alb_origin_verify.result]
    }
  }
}
```

- [ ] **Step 2: Validate and plan**

```bash
cd terraform
terraform fmt .
terraform validate
terraform plan -var-file=environments/beta.tfvars
```

Expected: `Success!`. Plan adds 6 resources (ALB, target group, 2 listeners, 2 listener rules).

- [ ] **Step 3: Commit**

```bash
git add terraform/alb.tf
git commit -m "Add Application Load Balancer with X-Origin-Verify enforcement"
git push
```

---

## Task 7: ECS cluster, task roles, and the three services

**Files:**
- Create: `terraform/modules/ecs_service/variables.tf`, `main.tf`, `outputs.tf`
- Create: `terraform/compute.tf`
- Modify: `terraform/variables.tf` (add per-service task count/CPU/memory variables)
- Modify: `terraform/environments/beta.tfvars`, `staging.tfvars`, `production.tfvars`

**Interfaces:**
- Consumes: `aws_subnet.app[*].id`, `aws_security_group.api/.worker/.scheduler.id` (Task 1); the ECR repo and media buckets from Task 2, referenced as literal strings, not Terraform state, since both are fully deterministic (see Task 2's Interfaces note); every secret ARN from Task 3; `aws_rds_cluster.this`/`aws_db_proxy.this`, `aws_elasticache_replication_group.this` (Tasks 4-5); `aws_lb_target_group.api.arn` (Task 6).
- Produces: `module.api_service.service_name`, `module.worker_service.service_name`, `module.scheduler_service.service_name` — used only by the verification task (Task 11), no other Terraform code depends on them.

**Deferred within this task** (flagged, not a gap to silently paper over): the API's `ALBRequestCountPerTarget` scaling policy and the worker's custom `BacklogPerTask` CloudWatch metric + policy (architecture doc §8.5) are not implemented here. Beta's `min_count = max_count = 1` means no autoscaling resource is created at all for beta regardless, so nothing here is untested-but-shipped; the module supports a CPU-based target-tracking policy generically for whenever staging (which does need scaling) is actually applied, but the request-rate and backlog-per-task policies are real follow-up work at that point.

- [ ] **Step 1: Add per-service sizing variables**

In `terraform/variables.tf`:

```hcl
variable "api_cpu" { type = number }
variable "api_memory" { type = number }
variable "api_min_count" { type = number }
variable "api_max_count" { type = number }

variable "worker_cpu" { type = number }
variable "worker_memory" { type = number }
variable "worker_min_count" { type = number }
variable "worker_max_count" { type = number }

variable "scheduler_cpu" { type = number }
variable "scheduler_memory" { type = number }
```

Append to `beta.tfvars` (architecture doc §17.2 — 0.5 vCPU/1GB, 1 task, no scaling):

```hcl
api_cpu          = 512
api_memory        = 1024
api_min_count     = 1
api_max_count     = 1

worker_cpu        = 512
worker_memory      = 1024
worker_min_count   = 1
worker_max_count   = 1

scheduler_cpu     = 512
scheduler_memory   = 1024
```

Append to `staging.tfvars` (doc §17.3 — 1 vCPU/2GB, API auto scales 2-4):

```hcl
api_cpu          = 1024
api_memory        = 2048
api_min_count     = 2
api_max_count     = 4

worker_cpu        = 1024
worker_memory      = 2048
worker_min_count   = 1
worker_max_count   = 1

scheduler_cpu     = 1024
scheduler_memory   = 2048
```

Append to `production.tfvars` (doc §17.4 / §8.4):

```hcl
api_cpu          = 1024
api_memory        = 2048
api_min_count     = 2
api_max_count     = 20

worker_cpu        = 2048
worker_memory      = 4096
worker_min_count   = 2
worker_max_count   = 10

scheduler_cpu     = 512
scheduler_memory   = 1024
```

- [ ] **Step 2: Write the `ecs_service` module — `terraform/modules/ecs_service/variables.tf`**

```hcl
variable "name" {
  description = "e.g. cs-beta-use1-api. Used for the service, task definition, and log group names."
  type        = string
}

variable "cluster_arn" { type = string }
variable "image" { type = string }
variable "command" { type = list(string) }
variable "container_port" {
  description = "null for worker/scheduler, which don't listen on a port."
  type        = number
  default     = null
}

variable "cpu" { type = number }
variable "memory" { type = number }
variable "min_count" { type = number }
variable "max_count" { type = number }

variable "subnet_ids" { type = list(string) }
variable "security_group_id" { type = string }
variable "task_role_arn" { type = string }
variable "execution_role_arn" { type = string }

variable "target_group_arn" {
  description = "null for services not behind the ALB (worker, scheduler)."
  type        = string
  default     = null
}

variable "capacity_provider_strategy" {
  type = list(object({
    capacity_provider = string
    weight            = number
    base              = optional(number)
  }))
}

variable "deployment_minimum_healthy_percent" {
  type    = number
  default = 100
}

variable "deployment_maximum_percent" {
  type    = number
  default = 200
}

variable "environment_vars" {
  type    = list(object({ name = string, value = string }))
  default = []
}

variable "secrets" {
  type    = list(object({ name = string, valueFrom = string }))
  default = []
}

variable "region" { type = string }
variable "log_retention_days" {
  type    = number
  default = 14
}
```

- [ ] **Step 3: Write `terraform/modules/ecs_service/main.tf`**

```hcl
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
      container_name    = var.name
      container_port    = var.container_port
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  lifecycle {
    ignore_changes = [desired_count] # auto scaling (when enabled) owns this
  }
}

resource "aws_appautoscaling_target" "this" {
  count              = var.max_count > var.min_count ? 1 : 0
  service_namespace  = "ecs"
  resource_id         = "service/${split("/", var.cluster_arn)[1]}/${aws_ecs_service.this.name}"
  scalable_dimension  = "ecs:service:DesiredCount"
  min_capacity        = var.min_count
  max_capacity         = var.max_count
}

# CPU target tracking only. Request-rate (API) and backlog-per-task
# (worker) policies are follow-up work for when staging/production are
# actually applied — see this task's header note.
resource "aws_appautoscaling_policy" "cpu" {
  count              = var.max_count > var.min_count ? 1 : 0
  name               = "${var.name}-cpu-target-tracking"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  resource_id         = aws_appautoscaling_target.this[0].resource_id
  scalable_dimension  = aws_appautoscaling_target.this[0].scalable_dimension
  policy_type         = "TargetTrackingScaling"

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown   = 300
    scale_out_cooldown  = 60
  }
}
```

- [ ] **Step 4: Write `terraform/modules/ecs_service/outputs.tf`**

```hcl
output "service_name" {
  value = aws_ecs_service.this.name
}

output "task_definition_arn" {
  value = aws_ecs_task_definition.this.arn
}
```

- [ ] **Step 5: Write `terraform/compute.tf`**

```hcl
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

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [
        aws_secretsmanager_secret.db_app.arn,
        aws_secretsmanager_secret.redis_auth.arn,
        aws_secretsmanager_secret.jwt.arn,
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
  shared_secrets = [
    { name = "DB_APP_CREDENTIALS", valueFrom = aws_secretsmanager_secret.db_app.arn },
    { name = "REDIS_AUTH", valueFrom = aws_secretsmanager_secret.redis_auth.arn },
  ]
  shared_env = [
    { name = "NODE_ENV", value = var.environment == "production" ? "production" : "development" },
    { name = "AWS_REGION", value = var.aws_region },
    { name = "DATABASE_PROXY_ENDPOINT", value = aws_db_proxy.this.endpoint },
    { name = "REDIS_ENDPOINT", value = aws_elasticache_replication_group.this.primary_endpoint_address },
  ]
}

module "api_service" {
  source = "./modules/ecs_service"

  name                = "${local.name_prefix}-api"
  cluster_arn         = aws_ecs_cluster.this.arn
  image               = local.ecr_image_uri
  command             = ["node", "dist/index.js"]
  container_port      = 3000
  cpu                 = var.api_cpu
  memory              = var.api_memory
  min_count           = var.api_min_count
  max_count           = var.api_max_count
  subnet_ids          = aws_subnet.app[*].id
  security_group_id   = aws_security_group.api.id
  task_role_arn       = aws_iam_role.api_task.arn
  execution_role_arn  = aws_iam_role.execution.arn
  target_group_arn    = aws_lb_target_group.api.arn
  region              = var.aws_region
  environment_vars    = local.shared_env
  secrets             = concat(local.shared_secrets, [{ name = "JWT_SIGNING_KEY", valueFrom = aws_secretsmanager_secret.jwt.arn }])

  capacity_provider_strategy = [{ capacity_provider = "FARGATE", weight = 1 }]
}

module "worker_service" {
  source = "./modules/ecs_service"

  name                = "${local.name_prefix}-worker"
  cluster_arn         = aws_ecs_cluster.this.arn
  image               = local.ecr_image_uri
  command             = ["node", "dist/worker.js"]
  cpu                 = var.worker_cpu
  memory              = var.worker_memory
  min_count           = var.worker_min_count
  max_count           = var.worker_max_count
  subnet_ids          = aws_subnet.app[*].id
  security_group_id   = aws_security_group.worker.id
  task_role_arn       = aws_iam_role.worker_task.arn
  execution_role_arn  = aws_iam_role.execution.arn
  region              = var.aws_region
  environment_vars    = local.shared_env
  secrets             = local.shared_secrets

  # Base 2 on-demand then FARGATE_SPOT only matters once worker_max_count
  # exceeds 2 (production). Beta/staging run a single task, all FARGATE.
  capacity_provider_strategy = var.worker_max_count > 2 ? [
    { capacity_provider = "FARGATE", weight = 0, base = 2 },
    { capacity_provider = "FARGATE_SPOT", weight = 1 },
  ] : [{ capacity_provider = "FARGATE", weight = 1 }]
}

module "scheduler_service" {
  source = "./modules/ecs_service"

  name                                = "${local.name_prefix}-scheduler"
  cluster_arn                         = aws_ecs_cluster.this.arn
  image                               = local.ecr_image_uri
  command                             = ["node", "dist/scheduler.js"]
  cpu                                 = var.scheduler_cpu
  memory                              = var.scheduler_memory
  min_count                           = 1
  max_count                           = 1
  subnet_ids                         = aws_subnet.app[*].id
  security_group_id                   = aws_security_group.scheduler.id
  task_role_arn                       = aws_iam_role.scheduler_task.arn
  execution_role_arn                  = aws_iam_role.execution.arn
  region                               = var.aws_region
  environment_vars                    = local.shared_env
  secrets                              = local.shared_secrets
  deployment_minimum_healthy_percent   = 0
  deployment_maximum_percent           = 100 # old task stops before the new one starts — never two schedulers at once

  capacity_provider_strategy = [{ capacity_provider = "FARGATE", weight = 1 }]
}
```

- [ ] **Step 6: Validate and plan**

```bash
cd terraform
terraform fmt .
terraform validate
terraform plan -var-file=environments/beta.tfvars
```

Expected: `Success!`. Plan adds the cluster, capacity providers, 5 IAM roles + their policies/attachments, and the 3 module instantiations (each: log group, task definition, service — `aws_appautoscaling_target`/`aws_appautoscaling_policy` show 0 for all three since beta's `min_count == max_count` everywhere). No errors resolving `aws_db_proxy.this.endpoint` or `aws_elasticache_replication_group.this.primary_endpoint_address` — if either shows as unresolvable, it means Task 4/5 weren't fully applied to state first; re-check those tasks. `local.ecr_image_uri` and `local.media_bucket_name` won't error even if Task 2 hasn't been applied yet in `global/` — they're plain strings, not state references — but the ECS services won't actually be able to pull an image or write media until Task 2 has been applied for real.

- [ ] **Step 7: Commit**

```bash
git add terraform/compute.tf terraform/modules/ecs_service terraform/variables.tf terraform/environments/*.tfvars
git commit -m "Add ECS cluster, task roles, and the API/worker/scheduler services"
git push
```

---

## Task 8: CloudFront `/api/*` edge integration

**Files:**
- Modify: `terraform/modules/cloudfront_spa/variables.tf` — `domain_name` (string) becomes `domain_names` (list(string)); add `alb_origin_domain_name`, `origin_verify_header_value` (both optional, default `null`)
- Modify: `terraform/modules/cloudfront_spa/main.tf` — `aliases`, plus a conditional ALB origin and `/api/*` behavior
- Modify: `terraform/locals.tf` — add `api_domain`
- Modify: `terraform/cdn.tf` — update both `module "web"` and `module "admin"` calls for the new variable name; pass the ALB params only to `web`
- Modify: `terraform/dns.tf` — add the `api_domain` alias records

**Interfaces:**
- Consumes: `aws_lb.this.dns_name` (Task 6); `random_password.alb_origin_verify.result` (Task 3).
- This is a breaking change to `cloudfront_spa`'s existing interface (`domain_name` → `domain_names`) — both existing callers (`web`, `admin`) must be updated in the same commit or `terraform plan` will fail with an undeclared variable error.

- [ ] **Step 1: Update `terraform/modules/cloudfront_spa/variables.tf`**

Find:

```hcl
variable "domain_name" {
  description = "CloudFront alternate domain name (CNAME), e.g. beta.curry.space."
  type        = string
}
```

Replace with:

```hcl
variable "domain_names" {
  description = "CloudFront alternate domain names (CNAMEs). The web distribution gets both its app hostname and its API hostname; admin gets just its own."
  type        = list(string)
}

variable "alb_origin_domain_name" {
  description = "ALB DNS name. When set, adds an ALB origin and a /api/* behavior. Leave null for distributions with no API path (admin)."
  type        = string
  default     = null
}

variable "origin_verify_header_value" {
  description = "Value CloudFront sends as X-Origin-Verify to the ALB origin. Required if alb_origin_domain_name is set."
  type        = string
  default     = null
  sensitive   = true
}
```

- [ ] **Step 2: Update `terraform/modules/cloudfront_spa/main.tf`**

Find:

```hcl
  aliases             = [var.domain_name]
```

Replace with:

```hcl
  aliases             = var.domain_names
```

Add these data sources near the top of the file, alongside the existing `data "aws_cloudfront_cache_policy" "caching_optimized"` block:

```hcl
data "aws_cloudfront_cache_policy" "caching_disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}
```

Add a second, conditional origin block right after the existing S3 `origin` block:

```hcl
  dynamic "origin" {
    for_each = var.alb_origin_domain_name == null ? [] : [1]
    content {
      domain_name = var.alb_origin_domain_name
      origin_id   = "alb-${var.name}"

      custom_origin_config {
        http_port              = 80
        https_port              = 443
        origin_protocol_policy   = "https-only"
        origin_ssl_protocols     = ["TLSv1.2"]
      }

      custom_header {
        name  = "X-Origin-Verify"
        value = var.origin_verify_header_value
      }
    }
  }
```

Add a conditional `/api/*` behavior right after the existing `default_cache_behavior` block:

```hcl
  dynamic "ordered_cache_behavior" {
    for_each = var.alb_origin_domain_name == null ? [] : [1]
    content {
      path_pattern               = "/api/*"
      allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods              = ["GET", "HEAD"]
      target_origin_id           = "alb-${var.name}"
      viewer_protocol_policy     = "redirect-to-https"
      cache_policy_id             = data.aws_cloudfront_cache_policy.caching_disabled.id
      origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    }
  }
```

- [ ] **Step 3: Add `api_domain` to `terraform/locals.tf`**

Add alongside the existing `web_domain`/`admin_domain` locals:

```hcl
  api_domain = var.environment == "production" ? "api.curry.space" : "${var.environment}-api.curry.space"
```

- [ ] **Step 4: Update `terraform/cdn.tf`**

Find the `module "web"` block and change:

```hcl
  domain_name             = local.web_domain
```

to:

```hcl
  domain_names            = [local.web_domain, local.api_domain]
  alb_origin_domain_name  = aws_lb.this.dns_name
  origin_verify_header_value = random_password.alb_origin_verify.result
```

Find the `module "admin"` block and change:

```hcl
  domain_name             = local.admin_domain
```

to:

```hcl
  domain_names            = [local.admin_domain]
```

(`admin` passes no ALB params — it has no API behavior, matching the architecture doc's explicit reasoning in §5.7 that admin calls the API directly as a cross-origin request rather than getting its own edge path.)

- [ ] **Step 5: Add DNS records for `api_domain` in `terraform/dns.tf`**

Add alongside the existing `web_a`/`web_aaaa` records, pointing at the same distribution (since `api_domain` is an alias on the `web` distribution, not a separate one):

```hcl
resource "aws_route53_record" "api_a" {
  zone_id = local.zone_id
  name    = local.api_domain
  type    = "A"

  alias {
    name                   = module.web.distribution_domain_name
    zone_id                = module.web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "api_aaaa" {
  zone_id = local.zone_id
  name    = local.api_domain
  type    = "AAAA"

  alias {
    name                   = module.web.distribution_domain_name
    zone_id                = module.web.distribution_hosted_zone_id
    evaluate_target_health = false
  }
}
```

- [ ] **Step 6: Validate and plan**

```bash
cd terraform
terraform fmt -recursive .
terraform validate
terraform plan -var-file=environments/beta.tfvars
```

Expected: `Success!`. Plan shows the `web` distribution as a **change** (new alias, new origin, new ordered cache behavior — CloudFront distribution updates in place, not replace), the `admin` distribution shows no changes (its alias list is still just its one domain, same as before, just renamed to `domain_names`), and 2 new `aws_route53_record` resources to add. If `admin`'s distribution shows as needing replacement rather than update, stop — that means the variable rename broke something; re-check Step 4's `admin` block has no leftover `domain_name` reference.

- [ ] **Step 7: Commit**

```bash
git add terraform/modules/cloudfront_spa terraform/locals.tf terraform/cdn.tf terraform/dns.tf
git commit -m "Extend CloudFront web distribution with /api/* routing to the ALB"
git push
```

---

## Task 9: CloudWatch alarms

**Files:**
- Create: `terraform/monitoring.tf`

**Interfaces:**
- Consumes: `aws_elasticache_replication_group.this.replication_group_id` (Task 5); `aws_rds_cluster.this.cluster_identifier`, `var.aurora_instance_count` (Task 4).
- The deployment circuit breaker (the third "hard requirement" alarm-shaped item from the spec) is **not** a separate resource here — it's already configured directly on each ECS service in Task 7's `ecs_service` module (`deployment_circuit_breaker { enable = true, rollback = true }`). Nothing further is needed for it; noted here only so the spec-coverage isn't misread as missing it.

- [ ] **Step 1: Write `terraform/monitoring.tf`**

```hcl
# No confirmed endpoint (email/Slack) to page yet — this topic exists so
# alarms have somewhere to publish to, but nobody is subscribed. Follow-up:
# aws sns subscribe once there's a real destination.
resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
}

# BullMQ job keys carry no TTL, so under memory pressure with the wrong
# eviction policy they'd be evicted instead of expiring — this is the
# alarm that catches getting maxmemory-policy wrong before jobs silently
# vanish (architecture doc §11.6).
resource "aws_cloudwatch_metric_alarm" "redis_memory" {
  alarm_name          = "${local.name_prefix}-redis-memory-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "DatabaseMemoryUsagePercentage"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Average"
  threshold           = 75
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.this.replication_group_id
  }
}

resource "aws_cloudwatch_metric_alarm" "redis_evictions" {
  alarm_name          = "${local.name_prefix}-redis-evictions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Evictions"
  namespace           = "AWS/ElastiCache"
  period              = 60
  statistic           = "Sum"
  threshold           = 0
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.this.replication_group_id
  }
}

# Only meaningful with a reader to lag behind the writer — beta has none
# (aurora_instance_count = 1), so this alarm isn't created for beta. It
# exists ready for when production (aurora_instance_count = 2) applies.
resource "aws_cloudwatch_metric_alarm" "aurora_replica_lag" {
  count               = var.aurora_instance_count > 1 ? 1 : 0
  alarm_name          = "${local.name_prefix}-aurora-replica-lag"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "AuroraReplicaLag"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = 1000 # milliseconds — architecture doc §12.3 alarms above 1 second
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    DBClusterIdentifier = aws_rds_cluster.this.cluster_identifier
  }
}
```

- [ ] **Step 2: Validate and plan**

```bash
cd terraform
terraform fmt .
terraform validate
terraform plan -var-file=environments/beta.tfvars
```

Expected: `Success!`. Plan adds 4 resources for beta (SNS topic, 2 ElastiCache alarms, 0 Aurora replica-lag alarms since `aurora_instance_count = 1`).

- [ ] **Step 3: Commit**

```bash
git add terraform/monitoring.tf
git commit -m "Add CloudWatch alarms for Redis memory/eviction and Aurora replica lag"
git push
```

---

## Task 10: Account-wide security services (`global/`)

**Files:**
- Create: `global/security.tf`

**Interfaces:**
- Independent of everything else in this plan — no other task's resources are consumed or produced here. This task can run before or after the others; it's placed last only because it lives in a different directory (`global/`, not `terraform/`) and doesn't block beta's backend from working.

- [ ] **Step 1: Write `global/security.tf`**

```hcl
# --- CloudTrail: all regions, log file validation, delivered to S3 + CloudWatch Logs.

resource "aws_s3_bucket" "cloudtrail" {
  bucket = "cs-cloudtrail-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "cloudtrail" {
  bucket                  = aws_s3_bucket.cloudtrail.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "cloudtrail_bucket" {
  statement {
    sid       = "AWSCloudTrailAclCheck"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.cloudtrail.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }

  statement {
    sid       = "AWSCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.cloudtrail.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }
}

resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = aws_s3_bucket.cloudtrail.id
  policy = data.aws_iam_policy_document.cloudtrail_bucket.json
}

resource "aws_cloudwatch_log_group" "cloudtrail" {
  name              = "/cloudtrail/cs-account"
  retention_in_days = 90
}

data "aws_iam_policy_document" "cloudtrail_logs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudtrail_logs" {
  name               = "cs-cloudtrail-logs"
  assume_role_policy = data.aws_iam_policy_document.cloudtrail_logs_assume.json
}

resource "aws_iam_role_policy" "cloudtrail_logs" {
  name = "cs-cloudtrail-logs-policy"
  role = aws_iam_role.cloudtrail_logs.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = ["${aws_cloudwatch_log_group.cloudtrail.arn}:*"]
    }]
  })
}

resource "aws_cloudtrail" "this" {
  name                       = "cs-account-trail"
  s3_bucket_name             = aws_s3_bucket.cloudtrail.id
  is_multi_region_trail      = true
  enable_log_file_validation = true
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_logs.arn

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# --- AWS Config: drift detection, default recorder covering all supported types.

resource "aws_s3_bucket" "config" {
  bucket = "cs-config-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "config_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "cs-config-recorder"
  assume_role_policy = data.aws_iam_policy_document.config_assume.json
}

resource "aws_iam_role_policy_attachment" "config" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

data "aws_iam_policy_document" "config_bucket" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.config.arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = data.aws_iam_policy_document.config_bucket.json
}

resource "aws_config_configuration_recorder" "this" {
  name     = "cs-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported = true
  }
}

resource "aws_config_delivery_channel" "this" {
  name           = "cs-config-channel"
  s3_bucket_name = aws_s3_bucket.config.id
  depends_on     = [aws_config_configuration_recorder.this, aws_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
  depends_on = [aws_config_delivery_channel.this]
}

# --- GuardDuty: watches VPC Flow Logs, DNS logs, and CloudTrail.

resource "aws_guardduty_detector" "this" {
  enable = true
}

# --- Security Hub: AWS Foundational Security Best Practices standard.

resource "aws_securityhub_account" "this" {}

resource "aws_securityhub_standards_subscription" "foundational" {
  standards_arn = "arn:aws:securityhub:us-east-1::standards/aws-foundational-security-best-practices/v/1.0.0"
  depends_on    = [aws_securityhub_account.this]
}
```

- [ ] **Step 2: Validate and plan**

```bash
cd global
terraform fmt .
terraform init \
  -backend-config="bucket=cs-tfstate-670794226662" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=cs-tfstate-lock"
terraform validate
terraform plan
```

Expected: `Success!`. Plan adds roughly 16 resources (2 S3 buckets + their public-access blocks and policies, 1 CloudWatch log group, CloudTrail's IAM role/policy/trail, Config's IAM role/attachment/recorder/channel/status, GuardDuty detector, Security Hub account + standard subscription). No changes to the existing ACM cert, Route 53 lookup, or the two IAM deploy roles already in `global/`.

- [ ] **Step 3: Apply**

```bash
terraform apply
```

This is safe to apply directly (no `-out=tfplan` gate needed) since it's account-wide and additive — nothing here touches beta/staging/production resources. Confirm the plan output matches what Step 2 showed before typing `yes`.

- [ ] **Step 4: Commit**

```bash
git add global/security.tf
git commit -m "Enable CloudTrail, AWS Config, GuardDuty, and Security Hub"
git push
```

---

## Task 11: Apply beta and verify end-to-end

**Files:** none — this task runs Terraform and AWS CLI checks, no code changes.

- [ ] **Step 1: Confirm `global/` is applied first**

Tasks 2 and 10 live in `global/`, not `terraform/`, and both need to have been actually applied before this step — not just planned — or the ECS services will come up with no image to pull and no bucket to write to, and the security services simply won't exist yet.

```bash
cd global
terraform plan
```

Expected: `No changes.` If it shows anything to add, go back and apply Task 2 and/or Task 10 before continuing.

- [ ] **Step 2: Plan the complete beta stack**

```bash
cd ../terraform
terraform init \
  -backend-config="bucket=cs-tfstate-670794226662" \
  -backend-config="key=envs/beta/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=cs-tfstate-lock"
terraform plan -var-file=environments/beta.tfvars -out=tfplan
```

Expected: a clean plan covering everything from Tasks 1, 3–9 together (VPC through the CloudWatch alarms — everything in `terraform/`, since Tasks 2 and 10 are in `global/` and already applied per Step 1). Read through the full resource list once before applying — this is the first time all of it is evaluated as a whole, and if any task above validated in isolation but conflicts with another (e.g., a duplicated name), it surfaces here.

- [ ] **Step 3: Apply**

```bash
terraform apply tfplan
```

This can take 10–15 minutes — Aurora cluster creation and the RDS Proxy in particular are slow. If using the GitHub Actions workflow instead of running locally, trigger `target: beta`, `action: apply` and watch the run rather than running these commands directly.

- [ ] **Step 4: Verify networking and security groups**

```bash
aws ec2 describe-vpcs --filters "Name=tag:Name,Values=cs-beta-use1-vpc" --query 'Vpcs[0].{VpcId:VpcId,CidrBlock:CidrBlock}'
aws ec2 describe-subnets --filters "Name=vpc-id,Values=<vpc-id-from-above>" --query 'Subnets[].{Id:SubnetId,Cidr:CidrBlock,AZ:AvailabilityZone,Tag:Tags[?Key==`Name`]|[0].Value}'
```

Expected: 1 VPC with CIDR `10.10.0.0/16`, 6 subnets (2 public, 2 app, 2 data) with the expected `/20` CIDRs and `Name` tags matching the `cs-beta-use1-{public,app,data}-{a,b}` pattern.

- [ ] **Step 5: Verify the ALB responds and enforces the header**

```bash
terraform output -raw web_url 2>/dev/null || echo "https://beta.curry.space"
curl -sI "https://beta.curry.space/api/healthz"
```

Expected: `HTTP/2 200` — this reaches CloudFront, which forwards to the ALB with the `X-Origin-Verify` header attached, which the priority-20 listener rule matches and returns a fixed 200 for, all without needing a single healthy ECS task. This is the key end-to-end proof that Tasks 1, 6, and 8 are wired correctly.

Then confirm the header enforcement directly against the ALB (bypassing CloudFront, which real clients can't do since the security group blocks non-CloudFront IPs — this specific check has to run from somewhere the security group allows, e.g. a Session Manager session in an app subnet, or temporarily allow your IP for this one test and revert):

```bash
curl -sI "https://<alb-dns-name>/healthz"
```

Expected: `HTTP/2 403` — no `X-Origin-Verify` header means the default action rejects it, proving the header check isn't decorative.

- [ ] **Step 6: Verify ECS services exist with the expected "no image" state**

```bash
aws ecs describe-services --cluster cs-beta-use1-cluster --services cs-beta-use1-api cs-beta-use1-worker cs-beta-use1-scheduler \
  --query 'services[].{Name:serviceName,Running:runningCount,Desired:desiredCount,Events:events[0].message}'
```

Expected: `runningCount: 0`, `desiredCount: 1` for all three, and the most recent event mentioning an image pull failure (e.g. `CannotPullContainerError` or `manifest for cs/app:placeholder not found`) — this is the expected state per this plan's Global Constraints, not a failure to fix. A "repository does not exist" error instead means Task 2 wasn't actually applied in `global/` — go back to Step 1.

- [ ] **Step 7: Verify the shared ECR repo and media buckets exist**

```bash
aws ecr describe-repositories --repository-names cs/app --query 'repositories[0].repositoryUri'
aws s3api head-bucket --bucket cs-nonprod-use1-media && echo "cs-nonprod-use1-media OK"
aws s3api head-bucket --bucket cs-prod-use1-media && echo "cs-prod-use1-media OK"
```

Expected: the repository URI prints, and both `head-bucket` calls succeed with no output other than the echoed confirmation. Beta and staging's task roles both point at `cs-nonprod-use1-media` — there is no `cs-beta-use1-media` or `cs-staging-use1-media` bucket, by design (decisions.md D-008).

- [ ] **Step 8: Verify Aurora and Redis are reachable only from inside the VPC**

```bash
aws rds describe-db-clusters --db-cluster-identifier cs-beta-use1-aurora-cluster \
  --query 'DBClusters[0].{Endpoint:Endpoint,Status:Status,Instances:DBClusterMembers[].DBInstanceIdentifier}'
aws elasticache describe-replication-groups --replication-group-id cs-beta-use1-redis \
  --query 'ReplicationGroups[0].{Status:Status,Endpoint:NodeGroups[0].PrimaryEndpoint.Address}'
```

Expected: both show `available`. Confirm neither endpoint resolves or connects from outside the VPC (no public IP, no route from the internet) — the data subnets have no NAT route and no internet gateway route by construction (Task 1), so this should fail closed by default; a positive verification is opening a Session Manager session on any instance in an app subnet and confirming `psql`/`redis-cli` **can** connect from there.

- [ ] **Step 9: Verify Secrets Manager entries exist and aren't empty (except JWT, deliberately)**

```bash
for s in db/master db/app redis/auth alb/origin-verify jwt; do
  echo "=== cs/beta/$s ==="
  aws secretsmanager get-secret-value --secret-id "cs/beta/$s" --query 'SecretString' --output text 2>&1 | sed 's/./*/g'
done
```

Expected: the first four show a masked non-empty value; `cs/beta/jwt` returns a "secret value not set" error — this is the one deliberately empty secret, and this error is the expected result, not a failure.

- [ ] **Step 10: Update decisions.md**

Add a new entry to `curryspace/docs/decisions.md` recording that backend phase 2 is live in beta with no real application image yet, so a future session doesn't mistake the "0 running tasks" state for a regression. Follow the existing D-00N numbering pattern in that file.

