# Backend Phase 2: VPC, ECS, Aurora, Redis, ALB, RDS Proxy

**Status:** Approved for implementation planning
**Date:** 2026-08-02

## Context

Phase 1 stood up the front-end-only infrastructure (S3, CloudFront, WAF, DNS, ACM) for all three environments, with beta fully live and serving a placeholder page. There is no backend compute, database, or cache yet — `curryspacefe` and `curry-space-admin-fe` can display pages but have no API to call.

This phase adds the backend infrastructure the architecture doc (`docs/curry-space-infrastructure-architecture.md`) already specifies in detail: networking, load balancing, ECS Fargate services (API/worker/scheduler), Aurora PostgreSQL, RDS Proxy, and ElastiCache Redis. The architecture doc's networking, ALB, ECS, Redis, Aurora, and environment-sizing sections (§3, §7, §8, §9, §11, §12, §17) are the source of truth for values; this spec's job is to translate them into a beta-first Terraform build using the same pattern phase 1 already established, and to resolve the handful of things the doc leaves as account-level choices (this account is single-account per decisions.md D-001, not the multi-account split the doc assumes in places).

**Outcome of this phase:** beta has a working VPC, ALB, ECS cluster with services created (not yet running real code — no backend app repo exists yet), Aurora cluster, Redis, and RDS Proxy, all wired together exactly as the architecture doc's security-group graph describes. Staging and production get the same Terraform with their own `.tfvars`, written now but not applied until beta is validated and the user says so — mirroring the beta → staging → production rollout phase 1 used.

## Decisions Carried Over From Discussion

These were resolved via clarifying questions before this spec was written; recorded here so the reasoning isn't lost:

1. **No real backend app image yet.** ECS task definitions, services, and the ALB target group get created, but there is no Docker image to run — services may sit with zero healthy tasks until a real backend app repo exists and pushes an image. This is intentional, not a bug to fix in this phase.
2. **Beta sizing follows the architecture doc's §17.2 table exactly** — no further shrinking. It's already near the practical floor (single instances, no HA, no auto scaling).
3. **Account-wide security services (GuardDuty, Security Hub, AWS Config, CloudTrail) are in scope**, going into `global/` since they're account-wide, not per-environment.
4. **Backend infra extends the existing `terraform/` root module** rather than a new root module or a new repo — same per-environment state, same `beta.tfvars`/`staging.tfvars`/`production.tfvars`, same GitHub Actions workflow. Zero new backend-config wiring.
5. **`beta`/`staging`/`production` Terraform applies continue using the existing admin `Github` IAM role** for this phase, not `cs-infra-deploy` — this phase needs `iam:CreateRole`/`iam:PassRole` for ECS task roles, which `cs-infra-deploy` deliberately doesn't have (see phase 1's README on why that role stays narrow).
6. **Media storage is two shared S3 buckets, not one per environment.** `cs-nonprod-use1-media` (beta and staging both write here) and `cs-prod-use1-media` — no further subdivision. This mirrors the ECR repository below: both are genuinely account-wide resources, so they belong in `global/`, not the per-environment `terraform/` — a second environment's `terraform/` apply would otherwise collide with the first (S3 bucket and ECR repository names are globally unique, not per-state).

## Scope

**In scope:**
- VPC, subnets (public/app/data tiers), NAT Gateway, VPC endpoints, security groups
- Application Load Balancer, listeners, target group, health checks
- Extending the existing public CloudFront distribution with an `/api/*` behavior routed to the ALB
- ECS cluster, task definitions (API/worker/scheduler + a one-off migration task shape), services, IAM task/execution roles
- Aurora PostgreSQL cluster + RDS Proxy
- ElastiCache Redis
- Secrets Manager containers for DB credentials, Redis auth, JWT signing keys
- The handful of "hard requirement" CloudWatch alarms the doc calls out by name (queue eviction risk, replica lag, deployment circuit breaker rollback)
- In `global/` (account-wide, shared across environments, not per-environment): the ECR repository for the future backend image, the two media S3 buckets (`cs-nonprod-use1-media`, `cs-prod-use1-media`), and the security services (GuardDuty, Security Hub, AWS Config, CloudTrail)

**Out of scope, deferred to later phases:**
- Backend application repo, Dockerfile, CI/CD build/deploy pipeline for the API image
- Full CloudWatch dashboards (doc §15.2)
- Blue/green deployments via CodeDeploy (doc's own "worth doing eventually" note, §14.6)
- Multi-region, cross-region backup copy, read replica auto scaling beyond beta's zero replicas
- Splitting Redis into separate BullMQ vs. cache clusters (doc flags this as a production-only "strongly worth doing" item, §11.1)
- Load-testing environment (doc §17.3 notes staging can't validate production's performance ceiling regardless; that needs its own short-lived environment later)

## Networking

One VPC per environment, CIDR per the doc's table: beta `10.10.0.0/16`, staging `10.20.0.0/16`, production `10.0.0.0/16` — deliberately non-overlapping so future VPC peering doesn't force a rebuild.

Subnets are computed from each environment's VPC CIDR via `cidrsubnet()` rather than hardcoded per environment, so the same Terraform produces the right layout for any of the three sizes:

| Tier | Purpose | AZ count |
|---|---|---|
| Public | ALB, NAT Gateway | 2 (beta, staging), 3 (production) |
| App (private) | ECS tasks | Same as public |
| Data (private) | Aurora, Redis, RDS Proxy | Same as public |

`map_public_ip_on_launch = false` on public subnets. Data subnets get no route to the NAT Gateway at all — they have no reason to reach the internet, and giving them a path there only creates an exfiltration route. NAT Gateway count matches the doc: 1 for beta and staging (accepted single point of failure), 3 for production (one per AZ).

VPC endpoints (S3 gateway, ECR api/dkr, logs, secretsmanager) are included from the start, in every environment — the doc is explicit these "pay for themselves" by keeping image pulls, log shipping, and secret fetches off the metered NAT path.

**Security groups** reference each other, never CIDR blocks, exactly per the doc's graph (§3.8): `sg-alb` → `sg-api` → `sg-rds-proxy` → `sg-aurora`, with `sg-worker` and `sg-scheduler` reaching `sg-rds-proxy` and `sg-redis` directly (no inbound rules at all — nothing calls them). `sg-alb`'s inbound 443 is restricted to the `com.amazonaws.global.cloudfront.origin-facing` managed prefix list, not `0.0.0.0/0` — this is what stops someone from finding the ALB's DNS name and hitting it directly, bypassing CloudFront and WAF entirely.

## Load Balancing & Edge Integration

One internet-facing ALB per environment, in the public subnets, 2 AZs (beta/staging) or matching production's AZ count. Listener 80 redirects permanently to 443. Listener 443 uses TLS policy `ELBSecurityPolicy-TLS13-1-2-2021-06` and the **same wildcard ACM certificate `global/` already created** — no new certificate needed, since compute lives in the same `us-east-1` region and account as CloudFront (the doc's original design assumed a separate non-prod AWS account requiring its own certificate copy; D-001 already collapsed that).

One target group, `cs-<env>-use1-api-tg`, port 8080, target type `ip` (required for Fargate's `awsvpc` mode), health check on `/health` expecting `200`, deregistration delay 30s. Routing: priority 20 returns a fixed 200 for `/health` directly at the ALB (so a health check doesn't need to reach a task at all); priority 100 forwards everything else to `api-tg`.

**`X-Origin-Verify` enforcement:** an ALB listener rule checks for a custom header (a random value generated by Terraform, stored in Secrets Manager, and configured as CloudFront's custom origin header) and returns a fixed 403 if it's missing or wrong. This is defense-in-depth on top of the security-group prefix-list restriction, matching the doc's Layer 1 diagram.

**Extending the existing public CloudFront distribution:** rather than a new distribution, the existing `web` distribution (from phase 1's `cloudfront_spa` module) gets:
- A second origin pointing at the ALB, with the custom `X-Origin-Verify` header
- A new `/api/*` behavior: `CachingDisabled` managed policy, all HTTP methods, `AllViewerExceptHostHeader` origin request policy (forwards headers/cookies through)
- An additional alternate domain name — `beta-api.curry.space` (and the staging/production equivalents) — alongside the existing `beta.curry.space` alias, both on the same distribution and covered by the existing wildcard certificate

This requires widening the `cloudfront_spa` module's interface: `domain_name` becomes `domain_names` (list), and two new optional variables (`alb_origin_domain_name`, `origin_verify_header_value`) that, when set, add the origin and behavior. The `admin` distribution passes neither — it has no API behavior, matching the doc's explicit reasoning that admin calls `api.curry.space` directly as a cross-origin request rather than getting its own edge path to the API.

Sticky sessions stay off everywhere, no exceptions — the API is stateless and there's nothing to be sticky about. ALB idle timeout stays at the 60s default.

## Compute: ECS on Fargate

One cluster per environment, `cs-<env>-use1-cluster`, capacity providers `FARGATE` and `FARGATE_SPOT`, Execute Command on (shell into a running task over SSM, no bastion needed).

A reusable `modules/ecs_service` module, instantiated three times:

| Service | Command | Port | Capacity strategy | Beta sizing |
|---|---|---|---|---|
| API | `node dist/main.js` | 8080 | 100% `FARGATE` | 1 task, 0.5 vCPU / 1 GB, no auto scaling |
| Worker | `node dist/worker.js` | none | Base 2 `FARGATE`, rest `FARGATE_SPOT` (production only — beta and staging both run a single worker task, all on `FARGATE`) | 1 task, 0.5 vCPU / 1 GB |
| Scheduler | `node dist/scheduler.js` | none | 100% `FARGATE` | 1 task, 0.5 vCPU / 1 GB |

Scheduler deployment uses `minimumHealthyPercent: 0, maximumPercent: 100` — the old task must stop before the new one starts, or two schedulers briefly coexist during a deploy and every cron fires twice. API and worker use the standard `100/200` rolling strategy. All three get the deployment circuit breaker with automatic rollback.

A fourth task definition shape (not a service) exists for the one-off migration task, sharing the same image and task role, run manually or by a future CI pipeline before a rolling deploy — this phase creates the task definition; actually running it is part of the future deploy pipeline, out of scope here.

**Image:** the container image field references the ECR repo this phase creates (`cs/app`), at a placeholder tag. No image will actually exist at that tag until a real backend repo builds and pushes one — per the earlier decision, services are expected to sit at zero healthy tasks until then. This is preferred over pointing at an unrelated public image, since it's the real path production will actually use.

**IAM**, one role per service per the doc's §19.1 table, each scoped to specific ARNs (no `Resource: "*"` outside genuinely account-wide read actions):
- `cs-<env>-api-task-role`: S3 `media/*` object access, `rds-db:connect` through the Proxy, Secrets Manager read on `cs/<env>/api/*`, log writes
- `cs-<env>-worker-task-role`: the above plus S3 `DeleteObject` on `temp/*`, SES send, SNS publish
- `cs-<env>-scheduler-task-role`: Redis/Aurora reads, log writes
- `cs-<env>-execution-role`: shared by all three, ECR pull + Secrets Manager read + log stream creation

Auto scaling resources (target tracking on CPU/request-rate for API, custom `BacklogPerTask` metric for workers) get created for every environment since the Terraform is shared, but beta's `min = max = 1` effectively disables scaling — matching the doc's "Auto Scaling: Off" for beta without needing separate conditional logic. Staging turns it on at 2–4 (doc's stated reason: an untested scaling policy is a bad thing to discover is broken in production).

## Data Layer

**Aurora PostgreSQL**, one cluster per environment:

| Environment | Instance class | Instances | RDS Proxy |
|---|---|---|---|
| Beta | `db.t4g.medium` (2 vCPU / 4 GB) | 1 writer, 0 readers | On |
| Staging | `db.t4g.large` (2 vCPU / 8 GB) | 1 writer, 0 readers | On |
| Production | `db.r7g.large` (2 vCPU / 16 GB) | 1 writer + 1 reader (to 3) | On |

RDS Proxy is on in every environment, including beta — not because beta needs the connection pooling at 1 task, but because it validates the IAM-auth + Secrets Manager wiring and the `node-postgres` driver behavior (§12.7's driver warning) before staging or production ever depend on it working. Engine family `POSTGRESQL`, TLS required, subnets in the data tier across both/all AZs.

Storage encryption on (KMS), deletion protection on in production only, Performance Insights on in production only (not supported on the `t4g` classes beta/staging use — slow query logging via `log_min_duration_statement = 1000` covers the gap). Backup retention: 1 day beta, 7 days staging, 35 days production, per the doc's table.

**ElastiCache Redis**, one cluster per environment:

| Environment | Node type | Topology |
|---|---|---|
| Beta | `cache.t4g.small` (2 vCPU / 1.37 GB) | Single node |
| Staging | `cache.t4g.medium` (2 vCPU / 3.09 GB) | 1 primary + 1 replica, Multi-AZ |
| Production | `cache.r7g.large` | 1 primary + 1 replica, Multi-AZ |

`maxmemory-policy` is `volatile-lru` everywhere — this is the setting that keeps BullMQ job keys (which carry no TTL) from being evicted under memory pressure instead of expired cache entries. Getting this wrong loses queued jobs with no error anywhere to explain it, per the doc's own warning. Encryption in transit (TLS) and at rest (KMS) on everywhere; AUTH token in Secrets Manager.

## Secrets Manager

Containers created by Terraform, values populated after apply (not generated blindly, except where a random value is the correct answer):

| Secret | Value source |
|---|---|
| `cs/<env>/db/master` | `random_password` at creation, Aurora's actual bootstrap credential |
| `cs/<env>/db/app` | `random_password` at creation, application DB user |
| `cs/<env>/redis/auth` | `random_password` at creation, Redis AUTH token |
| `cs/<env>/alb/origin-verify` | `random_password` at creation, the `X-Origin-Verify` header value |
| `cs/<env>/jwt` | Empty at creation — needs a real signing key filled in manually once the backend app exists, since Terraform generating a JWT signing secret nobody's tracked the rotation of is worse than leaving it explicitly empty |

## Shared Resources (`global/`)

Two things that are genuinely account-wide rather than per-environment, so they go in `global/` alongside the ACM certificate and the OIDC deploy roles — not in the per-environment `terraform/`, where a second environment's apply would collide with the first over a globally-unique name.

**ECR:** one repository, `cs/app` (matches the doc's reasoning — one image serves API, worker, scheduler, and the migration task via different entrypoints, so a second repository would just double the build/scan/lockstep burden for no benefit). Tag immutability on, scan-on-push on, lifecycle rules per the doc (§14.7): untagged expires after 1 day, `sha-` tags keep the newest 30. Referenced from `terraform/` by constructing the image URI as a literal string (`<account-id>.dkr.ecr.us-east-1.amazonaws.com/cs/app:<tag>`) rather than a remote-state lookup, since ECR URIs are fully deterministic.

**Media storage:** two S3 buckets, `cs-nonprod-use1-media` (beta and staging share this one) and `cs-prod-use1-media`. No per-layer or per-purpose subdivision — one bucket per tier is the whole design. Private, encrypted, versioned. Referenced from `terraform/`'s task role policies the same way as the ECR URI: a literal ARN string built from the environment's tier (`production` → `prod`, anything else → `nonprod`), not a remote-state lookup.

## Account-Wide Security Services (`global/`)

New `global/security.tf`:
- **CloudTrail**: all regions, log file validation on, delivered to a new S3 bucket + CloudWatch Logs
- **AWS Config**: recording on for the account, using the default recorder
- **GuardDuty**: detector enabled, watching VPC Flow Logs, DNS logs, and CloudTrail
- **Security Hub**: enabled with the AWS Foundational Security Best Practices standard

These are account-wide singletons — one of each, not one per environment — which is why they belong in `global/` alongside the ACM certificate rather than in the per-environment `terraform/`.

## Environments Side by Side

| | Beta | Staging | Production |
|---|---|---|---|
| VPC CIDR | `10.10.0.0/16` | `10.20.0.0/16` | `10.0.0.0/16` |
| AZs | 2 | 2 | 3 |
| NAT Gateways | 1 | 1 | 3 |
| API/Worker/Scheduler tasks | 1/1/1 | 2/1/1 | 2–20/2–10/1 |
| Fargate per task | 0.5 vCPU / 1 GB | 1 vCPU / 2 GB | varies by service (doc §8.4) |
| Auto scaling | Off (min=max=1) | On, 2–4 | On, full ranges |
| Aurora | `db.t4g.medium`, 1 instance | `db.t4g.large`, 1 instance | `db.r7g.large`, writer+reader |
| Redis | `cache.t4g.small`, single node | `cache.t4g.medium`, +1 replica | `cache.r7g.large`, +1 replica |
| Backup retention | 1 day | 7 days | 35 days |

Staging and production `.tfvars` are written in this phase but **not applied** until beta is validated end-to-end and the user explicitly asks — same phased rollout as phase 1.

## Verification Plan

Once beta is applied:
1. `terraform plan`/`apply` completes clean for `target: beta` through the existing GitHub Actions workflow.
2. Confirm the VPC, subnets, and security groups exist with the expected CIDR/tier layout (`aws ec2 describe-subnets`, or via the Terraform outputs).
3. Confirm the ALB responds on 443 with a valid certificate; `/health` fixed-response rule returns 200 directly from the ALB without touching a target.
4. Confirm `https://beta.curry.space/api/health` (through CloudFront) reaches the ALB and gets the same fixed 200 — this validates the edge integration end-to-end even with zero real backend tasks running, since the ALB-level fixed-response rule doesn't need a healthy target.
5. Confirm the ECS services exist and show 0/1 running tasks with a clear "image not found" or similar failure reason in the service events — this is the expected state per the "Terraform only" decision, not a bug.
6. Confirm Aurora and Redis are reachable from a temporary bastion/Session Manager session in the app subnet (not from the public internet — data subnets have no route out).
7. Confirm Secrets Manager entries exist with the expected names, and that the random-generated ones have real values (not empty).
