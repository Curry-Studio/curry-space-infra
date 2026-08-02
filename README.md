# curry-space-infra

Terraform for Curry Space infrastructure. **Phase 1 (front-end — S3, CloudFront, ACM, Route 53, WAF)** is applied to beta, staging, and production. **Phase 2 (backend — VPC, Aurora + RDS Proxy, ElastiCache Redis, ALB, ECS, CloudFront `/api/*` integration, CloudWatch alarms, account-wide security services)** is applied and verified end-to-end in beta only; staging/production come next.

Decisions behind the choices in this repo are logged in the `curryspace` project's `docs/decisions.md` — check there before changing naming, account structure, or the admin WAF posture.

## Layout

```
bootstrap/      Terraform state backend (S3 + DynamoDB). Local state, committed back to the repo by CI. Run once, before anything else.
global/         Account-wide, shared-across-environments resources: ACM wildcard cert, Route 53 zone lookup,
                OIDC deploy roles, shared ECR repo (cs/app), nonprod/prod media buckets, CloudTrail/Config/
                GuardDuty/Security Hub.
terraform/      Per-environment infra, front-end and backend together: S3 buckets, CloudFront, WAF, DNS,
                VPC/subnets/NAT, security groups, Secrets Manager, Aurora + RDS Proxy, Redis, ALB, ECS
                cluster + api/worker/scheduler services, CloudWatch alarms. Applied once per environment
                (beta/staging/production).
terraform/modules/cloudfront_spa/   Reusable module: one S3-backed SPA behind CloudFront + OAC, with an
                                     optional ALB origin and /api/* behavior (used by `web`, not `admin`).
terraform/modules/ecs_service/      Reusable module: one ECS Fargate service + task role + autoscaling.
terraform/environments/*.tfvars     Per-environment variable values.
```

## Why three separate applies

Terraform backend blocks can't reference variables — the S3 bucket/key for state has to be literal or passed at `init` time. `global/` and each environment in `terraform/` are separate state files in the same bucket (single account, D-001), not separate directories by accident.

## Running it — everything via GitHub Actions

This account has an IAM role (`Github`) trusted by the GitHub OIDC provider for the whole `Curry-Studio` org, with `AdministratorAccess` attached. Every apply in this repo — phase 1 and phase 2 — has run through `.github/workflows/terraform.yml` using that role; nobody has needed to run Terraform locally or hold AWS credentials on a laptop, except for the read-only AWS CLI verification checks below.

From the Actions tab, run the **Terraform** workflow via **Run workflow**, picking a `target` (`bootstrap` / `global` / `beta` / `staging` / `production`) and `action` (`plan` or `apply`). Run `plan` first on anything you're unsure about — it's the same workflow, no apply happens.

**Order for a brand-new environment:** `bootstrap` → `global` → the environment (`beta`, then `staging`, then `production`). `global` and `bootstrap` only need re-applying when their own files change.

### Running it locally instead (fallback)

If you'd rather not wait on Actions, the same steps work from a laptop with admin AWS credentials configured:

```bash
cd bootstrap && terraform init && terraform apply   # note the state_bucket_name output
cd ../global && terraform init \
  -backend-config="bucket=<state_bucket_name>" -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=cs-tfstate-lock" && terraform apply
cd ../terraform && terraform init \
  -backend-config="bucket=<state_bucket_name>" -backend-config="key=envs/beta/terraform.tfstate" \
  -backend-config="region=us-east-1" -backend-config="dynamodb_table=cs-tfstate-lock"
terraform plan -var-file=environments/beta.tfvars
terraform apply -var-file=environments/beta.tfvars
```

Always check `terraform plan` output confirms the environment you expect before approving an apply — §D-001 in decisions.md: all three environments share one AWS account, so there's no account-boundary safety net.

## Verifying beta

Front-end (no credentials needed):

```bash
curl -I https://beta.curry.space        # expect a CloudFront/S3 response, not a cert error
curl -I https://beta-admin.curry.space  # same — reachable without an allow-list, per D-005
```

Backend edge path (no credentials needed — proves CloudFront → TLS → ALB → header-check wiring, independent of whether any ECS task is running):

```bash
curl -I https://beta.curry.space/api/healthz   # expect 200 from the ALB's fixed-response rule
```

Backend AWS-side state (needs read access to the account — see `docs/decisions.md` D-010 for the full checklist and the bugs a real apply surfaced that `terraform validate` couldn't catch):

```bash
aws ecs describe-services --cluster cs-beta-use1-cluster \
  --services cs-beta-use1-api cs-beta-use1-worker cs-beta-use1-scheduler \
  --query 'services[].{Name:serviceName,Running:runningCount,Desired:desiredCount}'
```

`runningCount: 0` on all three is expected right now, not a regression — see "What's left" below.

## CI/CD

`.github/workflows/terraform.yml`:

- **On a PR** touching `global/` or `terraform/`: runs `terraform plan` for every target for visibility. Never applies.
- **Manual only** (`workflow_dispatch`): pick a target and `plan` or `apply`. Each target maps to a GitHub Environment of the same name — add required reviewers on `production` (and `global`) under repo Settings → Environments, so an apply needs a human approval. This is the safety net standing in for the account boundary D-001 gave up. `bootstrap` has no environment protection since it only touches the state bucket/lock table.

### Hardening later: swapping to the narrower role

`AWS_ROLE_ARN` still points at the existing `Github` admin role — it already exists and already works, and getting phase 1 and phase 2 live mattered more than least-privilege so far. `global/iam.tf` also creates `cs-infra-deploy`, scoped to S3/CloudFront/WAF/Route53/ACM plus the state bucket/lock table — narrow enough for phase 1, **not** wide enough for phase 2 (it has no EC2/RDS/ElastiCache/ECS/IAM permissions), so it would need widening before it could stand in for backend applies. Not done yet.

## What's left

- **No application image exists yet.** `curryspacebe` has a `Dockerfile` but no CI/CD pipeline builds or pushes it to the shared ECR repo (`cs/app`). All three beta ECS services (api/worker/scheduler) sit at `runningCount: 0` with a `CannotPullContainerError` on the placeholder tag — by design, not a bug (decisions.md D-010). Next concrete step: a narrowly-scoped `cs-be-deploy` OIDC role (ECR push + `ecs:UpdateService`) plus a build-and-push workflow in `curryspacebe`, so beta runs one real image before anything promotes to staging.
- **Backend (phase 2) is beta-only.** `staging.tfvars`/`production.tfvars` have backend variables written but never applied — same promotion path as phase 1 (`target: staging`, then `target: production`), once beta is running a real image and worth promoting.
- **Admin WAF is open (default Allow) in every environment.** decisions.md D-005. Target design (default Block + IP allow-list) is a config change (`admin_waf_default_action = "BLOCK"` + populate `admin_allowed_ip_set`) once real CIDRs exist.
- **WAF rule set is a subset.** Managed core rule groups + a general rate limit only. SQLi/Linux managed rule sets, per-path rate limits (`/api/auth/*`, `/api/upload/*`, `/api/admin/*`), geo blocking, and Bot Control are still deferred. (The ALB origin-header check that used to be listed here is done — CloudFront's `/api/*` behavior and the ALB's listener rules now enforce the `X-Origin-Verify` header end-to-end.)
- **`AWS_ROLE_ARN` is still the admin `Github` role.** See "Hardening later" above.
