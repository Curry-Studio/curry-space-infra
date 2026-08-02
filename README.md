# curry-space-infra

Terraform for Curry Space infrastructure. Phase 1 (current): front-end only — S3, CloudFront, ACM, Route 53, WAF. ECS/Aurora/ALB/Redis come in phase 2, once the backend repo exists.

Decisions behind the choices in this repo are logged in the `curryspace` project's `docs/decisions.md` — check there before changing naming, account structure, or the admin WAF posture.

## Layout

```
bootstrap/      Terraform state backend (S3 + DynamoDB). Local state, committed back to the repo by CI (see README below). Run once, before anything else.
global/         Account-wide, shared-across-environments resources: the ACM wildcard cert, Route 53 zone lookup.
terraform/      Per-environment front-end infra: S3 buckets, CloudFront, WAF, DNS records. Applied once per environment (beta/staging/production).
terraform/modules/cloudfront_spa/   Reusable module: one S3-backed SPA behind CloudFront + OAC.
terraform/environments/*.tfvars     Per-environment variable values.
```

## Why three separate applies

Terraform backend blocks can't reference variables — the S3 bucket/key for state has to be literal or passed at `init` time. `global/` and each environment in `terraform/` are separate state files in the same bucket (single account, D-001), not separate directories by accident.

## First-time setup — everything via GitHub Actions

This account already has an IAM role (`Github`) trusted by the GitHub OIDC provider for the whole `Curry-Studio` org, with `AdministratorAccess` attached. That's enough to run every step below through `.github/workflows/terraform.yml` — nobody needs to run Terraform locally or hold AWS credentials on a laptop.

Before the first run, set two repository variables (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::670794226662:role/Github` (the existing OIDC-trusted admin role) |
| `STATE_BUCKET` | `cs-tfstate-670794226662` (deterministic: `cs-tfstate-<account-id>`, created by the bootstrap run below) |

Then, from the Actions tab, run the **Terraform** workflow via **Run workflow** four times in order, `action: apply` each time:

1. **`target: bootstrap`** — creates the state bucket + lock table. Has no remote backend to persist to (it creates the backend), so its state is checked out from and committed straight back to the repo by the workflow itself — see the "Commit bootstrap state" step. This is the one target that's safe to re-run; it's a no-op once the bucket/table exist.
2. **`target: global`** — creates the shared `*.curry.space` ACM cert (DNS-validated via the existing Route 53 zone) and a narrower, purpose-built deploy role (`cs-infra-deploy`) for future hardening. Every environment's CloudFront distributions depend on the cert this creates.
3. Edit `terraform/environments/{beta,staging,production}.tfvars` — replace `cs-tfstate-REPLACE_WITH_ACCOUNT_ID` with `cs-tfstate-670794226662`, commit. (One-time; same value in all three.)
4. **`target: beta`** — creates beta's S3 buckets, CloudFront distributions, WAF ACLs, and DNS records.

Repeat with `target: staging` / `target: production` when ready. Run `action: plan` first on anything you're unsure about — it's the same workflow, no apply happens.

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

## Testing beta once applied

```bash
curl -I https://beta.curry.space        # expect a CloudFront/S3 response, not a cert error
curl -I https://beta-admin.curry.space   # same — reachable without an allow-list, per D-005
```

Both buckets are empty until the front-end CI pushes a build, so a 403/blank body at this stage is expected — the check is that TLS and routing work, not that there's content yet.

## CI/CD

`.github/workflows/terraform.yml`:

- **On a PR** touching `global/` or `terraform/`: runs `terraform plan` for every target (global, beta, staging, production) for visibility. Never applies.
- **Manual only** (`workflow_dispatch`): pick a target and `plan` or `apply`. Each target maps to a GitHub Environment of the same name — add required reviewers on `production` (and `global`, since the ACM cert lives there) under repo Settings → Environments, so an apply needs a human approval. This is the safety net standing in for the account boundary D-001 gave up. `bootstrap` has no environment protection since it only touches the state bucket/lock table.

### Hardening later: swapping to the narrower role

`AWS_ROLE_ARN` points at the existing `Github` admin role for now — it already exists and already works, and getting beta live matters more today than least-privilege. `global/iam.tf` also creates `cs-infra-deploy`, a role scoped to only S3/CloudFront/WAF/Route53/ACM plus the state bucket/lock table. Once `global` has been applied, you can point `AWS_ROLE_ARN` at that role's ARN (`github_actions_role_arn` output) instead — for the `beta`/`staging`/`production` targets only; `global` itself needs IAM permissions to manage its own role, which `cs-infra-deploy` deliberately doesn't have (a role that can edit its own trust policy is a privilege-escalation smell), so keep `global` and `bootstrap` on the admin role.

## Known gaps in this phase (by design, not oversight)

- **Admin WAF is open (default Allow) in every environment.** decisions.md D-005. The target design (default Block + IP allow-list) is documented in the architecture doc §5.7/§6.1 and is a config change (`admin_waf_default_action = "BLOCK"` + populate `admin_allowed_ip_set`) once real CIDRs exist.
- **WAF rule set is a subset.** Managed core rule groups + a general rate limit only. SQLi/Linux managed rule sets, per-path rate limits (`/api/auth/*`, `/api/upload/*`, `/api/admin/*`), geo blocking, Bot Control, and the ALB origin-header check are deferred to the backend phase, since they target paths that don't exist until the ALB/API does.
- **No ECS, Aurora, Redis, ALB, or VPC yet.** Phase 2.
