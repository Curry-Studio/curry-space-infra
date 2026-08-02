# curry-space-infra

Terraform for Curry Space infrastructure. Phase 1 (current): front-end only — S3, CloudFront, ACM, Route 53, WAF. ECS/Aurora/ALB/Redis come in phase 2, once the backend repo exists.

Decisions behind the choices in this repo are logged in the `curryspace` project's `docs/decisions.md` — check there before changing naming, account structure, or the admin WAF posture.

## Layout

```
bootstrap/      Terraform state backend (S3 + DynamoDB). Local state. Run once, manually, before anything else.
global/         Account-wide, shared-across-environments resources: the ACM wildcard cert, Route 53 zone lookup.
terraform/      Per-environment front-end infra: S3 buckets, CloudFront, WAF, DNS records. Applied once per environment (beta/staging/production).
terraform/modules/cloudfront_spa/   Reusable module: one S3-backed SPA behind CloudFront + OAC.
terraform/environments/*.tfvars     Per-environment variable values.
```

## Why three separate applies

Terraform backend blocks can't reference variables — the S3 bucket/key for state has to be literal or passed at `init` time. `global/` and each environment in `terraform/` are separate state files in the same bucket (single account, D-001), not separate directories by accident.

## First-time setup

### 1. Bootstrap the state backend (once, ever)

```bash
cd bootstrap
terraform init
terraform apply
```

This has no remote backend — it runs with local state on whoever's machine applies it. Keep `bootstrap/terraform.tfstate` safe (commit it to a private location or hand it to whoever manages this repo next; it's small and changes rarely). Note the `state_bucket_name` output — you'll need it below.

### 2. Apply the global config (once, ever — unless a real second AWS account gets introduced)

```bash
cd ../global
terraform init \
  -backend-config="bucket=<state_bucket_name from step 1>" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=cs-tfstate-lock"
terraform apply
```

Creates the `*.curry.space` + `curry.space` ACM certificate (DNS-validated via the existing Route 53 zone) that every environment's CloudFront distributions use.

### 3. Fill in `state_bucket` in the tfvars files

Edit `terraform/environments/beta.tfvars`, `staging.tfvars`, and `production.tfvars` — replace `cs-tfstate-REPLACE_WITH_ACCOUNT_ID` with the real bucket name from step 1. Same value in all three; it's a lookup key for the remote-state data source, not a per-environment setting.

### 4. Apply an environment — beta first

```bash
cd ../terraform
terraform init \
  -backend-config="bucket=<state_bucket_name>" \
  -backend-config="key=envs/beta/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=cs-tfstate-lock"
terraform plan -var-file=environments/beta.tfvars
terraform apply -var-file=environments/beta.tfvars
```

For staging/production, `terraform init` again with `key=envs/staging/terraform.tfstate` (or `envs/production/...`) and the matching `-var-file`. Re-running `init` with a different `key` switches which environment's state this working directory points at — always check `terraform plan` output confirms the environment you expect before approving an apply (§D-001 in decisions.md: all three environments share one AWS account, so there's no account-boundary safety net).

## Testing beta once applied

```bash
curl -I https://beta.curry.space        # expect a CloudFront/S3 response, not a cert error
curl -I https://beta-admin.curry.space   # same — reachable without an allow-list, per D-005
```

Both buckets are empty until the front-end CI pushes a build, so a 403/blank body at this stage is expected — the check is that TLS and routing work, not that there's content yet.

## CI/CD

`.github/workflows/terraform.yml`:

- **On a PR** touching `global/` or `terraform/`: runs `terraform plan` for every target (global, beta, staging, production) for visibility. Never applies.
- **Manual only** (`workflow_dispatch`): pick a target and `plan` or `apply`. Each target maps to a GitHub Environment of the same name — add required reviewers on `production` (and `global`, since the ACM cert and the deploy role itself live there) under repo Settings → Environments, so an apply needs a human approval. This is the safety net standing in for the account boundary D-001 gave up.

Before the workflow can run, set two repository variables (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | `github_actions_role_arn` output from `global` after you apply it |
| `STATE_BUCKET` | `state_bucket_name` output from `bootstrap` |

## Known gaps in this phase (by design, not oversight)

- **Admin WAF is open (default Allow) in every environment.** decisions.md D-005. The target design (default Block + IP allow-list) is documented in the architecture doc §5.7/§6.1 and is a config change (`admin_waf_default_action = "BLOCK"` + populate `admin_allowed_ip_set`) once real CIDRs exist.
- **WAF rule set is a subset.** Managed core rule groups + a general rate limit only. SQLi/Linux managed rule sets, per-path rate limits (`/api/auth/*`, `/api/upload/*`, `/api/admin/*`), geo blocking, Bot Control, and the ALB origin-header check are deferred to the backend phase, since they target paths that don't exist until the ALB/API does.
- **No ECS, Aurora, Redis, ALB, or VPC yet.** Phase 2.
