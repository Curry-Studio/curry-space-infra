# Proto: a lightweight, front-end-only preview environment

**Status:** Approved for implementation planning
**Date:** 2026-09-15

## Context

`curryspacefe`'s `beta` branch deploys to `beta.curry.space` today, wired up by
`curry-space-infra`'s per-environment `terraform/` root module (which also
provisions `curryspacebe`'s beta backend — VPC, Aurora, Redis, ECS, ALB,
`beta-api.curry.space`). We want a second, independent preview surface:
`curryspacefe`'s `proto` branch (already created) deployed to
`proto.curry.space`.

`curryspacefe`'s web build is a static SPA that does not call `curryspacebe`'s
API directly — auth goes through Firebase, feed data through a separate
CORS-proxy Worker. `proto` therefore needs no backend: no VPC, no ECS, no
Aurora, no Redis, no ALB, no `proto-api.curry.space`.

The account's shared wildcard ACM certificate (`*.curry.space`) and the
Route 53 hosted zone are both global (`global/acm.tf`, `global/dns.tf`) and
already cover `proto.curry.space` — no new certificate or DNS delegation
work is needed.

**Hard constraint carried into every decision below: this must not touch
`curryspacebe`'s beta API/backend, and must not change how any of
beta/staging/production build or deploy in the future.** See "Safety" below
for how each piece of this design satisfies that.

## Decisions carried over from discussion

1. **Front-end only, no backend.** Confirmed with the user: `proto` is a
   static-site preview, not a full environment clone.
2. **`curryspacefe` only**, not `curry-space-admin-fe` — no
   `proto-admin.curry.space` for now.
3. **New, separate Terraform stack**, not a 4th value on the existing
   `terraform/` module's `environment` variable. Conditionalizing VPC/ECS/
   Aurora/Redis/ALB out of `terraform/` for one boolean flag would touch
   ~10 files that beta/staging/production depend on today — unnecessary risk
   for a static site. A new, isolated stack with its own state file can't
   affect that state no matter what it does.
4. **`proto` git branch already exists** in `curryspacefe` — not part of this
   implementation.

## Scope

**In scope:**
- New Terraform root module `terraform-web-preview/` in `curry-space-infra`:
  one S3-backed CloudFront distribution (reusing the existing
  `terraform/modules/cloudfront_spa` module unchanged), a logs bucket, a
  public WAF ACL, and Route 53 A/AAAA aliases for `proto.curry.space`.
  Parameterized by a `preview_name` variable (`environments/proto.tfvars` →
  `preview_name = "proto"`) so a future preview environment is a new tfvars
  file, not new code.
- One-line addition to `global/fe-deploy-iam.tf`'s `fe_bucket_arns` list so
  the existing `cs-fe-deploy` OIDC role can sync/invalidate the new bucket.
- A new `proto-web` `workflow_dispatch` target in
  `curry-space-infra/.github/workflows/terraform.yml`, additive only.
- `curryspacefe/.github/workflows/deploy.yml`: add `proto` to
  `on.push.branches`.
- A new GitHub Environment named `proto` in `curryspacefe`'s repo settings
  (manual, one-time, same as beta/staging today) holding `AWS_ROLE_ARN`
  (existing `cs-fe-deploy` role ARN, unchanged), `S3_BUCKET`, and
  `CF_DISTRIBUTION_ID` (the latter two copied from the Terraform apply's
  outputs).
- `enable_noindex = true` on the proto distribution (`X-Robots-Tag:
  noindex, nofollow`) — it's a preview surface, not meant to be indexed.

**Out of scope:**
- Any backend/API infrastructure for proto.
- `curry-space-admin-fe` / `proto-admin.curry.space`.
- Any change to `terraform/`, `terraform/environments/*.tfvars`,
  `curryspacebe`, or the (not-yet-created) `cs-be-deploy` role.
- Adding `proto-web` to the PR-triggered `plan-on-pr` matrix — kept manual
  (`workflow_dispatch`) only, so no existing PR workflow behavior changes.

## Safety: why beta's API and future deployments are unaffected

| Change | Blast radius |
|---|---|
| New `terraform-web-preview/` stack, own state file (`envs/preview-proto/terraform.tfstate`) | Zero overlap with `terraform/`'s state (beta/staging/production). Terraform only ever acts on resources tracked in the state file it's initialized against — a `proto-web` apply cannot see or touch beta's VPC/ECS/Aurora/ALB resources. |
| `global/fe-deploy-iam.tf`: append one S3 ARN pair to the existing `fe_deploy_permissions` policy document | Purely additive (`fe_bucket_arns` list grows by one entry). `terraform plan` against `global` will show exactly one changed resource (`aws_iam_role_policy.fe_deploy_permissions`, updated in place) and nothing else, assuming no unrelated drift — verify this with `plan` before `apply`, per the repo's existing convention. Doesn't touch `global/be-deploy-iam.tf`, `iam.tf`, `acm.tf`, `dns.tf`, `ecr.tf`, `media.tf`, or `security.tf`. |
| `curry-space-infra/.github/workflows/terraform.yml`: new `proto-web` choice + steps | The existing `run` job's generic "environment" steps are guarded by `if: inputs.target != 'global' && inputs.target != 'bootstrap'`; adding `&& inputs.target != 'proto-web'` alongside new `if: inputs.target == 'proto-web'` steps means beta/staging/production's `inputs.target` values are unaffected by the added condition (still `true`/`false` exactly as before) — this is proven by inspection, not just by intent, and will be double-checked in the PR diff. |
| `curryspacefe/.github/workflows/deploy.yml`: add `proto` to `push.branches` | `beta`, `staging`, `main` entries and the `environment: ${{ github.ref_name == 'main' && 'production' || github.ref_name }}` expression are untouched — `proto` simply becomes a fourth trigger branch, resolving to a `proto` GitHub Environment the same way `beta` resolves to a `beta` one today. |
| No changes to `curryspacebe` | This repo isn't touched at all — beta's backend deploy path (once it exists) is unaffected by definition. |

## Terraform: `terraform-web-preview/`

Mirrors the relevant slice of `terraform/` (`cdn.tf`'s `module "web"`,
`dns.tf`'s web records, `storage.tf`'s logs bucket, `waf.tf`'s public ACL,
`locals.tf`'s naming) at a fraction of the size:

```
terraform-web-preview/
  main.tf              # backend "s3" {} partial config, provider, remote_state → global
  variables.tf         # preview_name (string, required)
  locals.tf            # name_prefix = "cs-${var.preview_name}-use1"
                        # web_domain  = "${var.preview_name}.curry.space"
  storage.tf            # logs bucket (same pattern as terraform/storage.tf)
  waf.tf                # public WAF ACL only (same managed_rule_groups, no admin ACL, no rate limiting)
  cdn.tf                # module "web" { source = "../terraform/modules/cloudfront_spa" ... }
  dns.tf                # web A/AAAA alias records only
  outputs.tf            # web_bucket_name, web_distribution_id, web_url
  environments/
    proto.tfvars         # preview_name = "proto"
```

State: same S3 bucket/DynamoDB lock table as everything else
(`cs-tfstate-<account-id>`, `cs-tfstate-lock`), key
`envs/preview-<name>/terraform.tfstate` — `envs/preview-proto/terraform.tfstate`
for this one. The `preview-` prefix keeps it visually distinct from
`envs/beta/…`, `envs/staging/…`, `envs/production/…` in the state bucket.

## CI

`terraform.yml`: add `proto-web` to the `workflow_dispatch` target choices,
and a new block of `init`/`plan`/`apply` steps (guarded by
`inputs.target == 'proto-web'`) pointing at `terraform-web-preview/` with
`-var-file=environments/proto.tfvars`. The existing `bootstrap`/`global`/
environment step blocks are otherwise untouched except for the added
`!= 'proto-web'` guard noted above.

`curryspacefe/deploy.yml`: `on.push.branches` gets `proto` appended.

## Rollout order

1. `global` target: `plan`, review the single-resource diff, then `apply`
   (adds the S3 ARNs for the new bucket to `cs-fe-deploy`'s policy).
2. `proto-web` target: `plan`, review, `apply` (creates the S3 bucket,
   CloudFront distribution, WAF ACL, logs bucket, DNS records).
3. Read `web_bucket_name` / `web_distribution_id` from the apply output.
4. Create the `proto` GitHub Environment in `curryspacefe`'s repo settings;
   set `AWS_ROLE_ARN` (copy from beta's environment), `S3_BUCKET`,
   `CF_DISTRIBUTION_ID` from step 3. Copy `CORS_PROXY_URL`/`FIREBASE_*`
   variables from beta's environment too, unless the user wants proto to
   point at different backing services.
5. Merge the `deploy.yml` branch-list change; push (or re-push) to `proto`.
6. Verify (see below).

## Verification

Mirrors the existing "Verifying beta" section in the repo README:

```bash
curl -I https://proto.curry.space   # expect a CloudFront/S3 response, not a cert error
```

Plus, before touching anything shared:
```bash
# From curry-space-infra, target=global, action=plan — confirm the diff is
# exactly the one IAM policy statement, nothing else.
```

And a sanity check that beta is untouched, run once after the `proto-web`
apply:
```bash
curl -I https://beta.curry.space
curl -I https://beta.curry.space/api/healthz
```

## Out of scope / follow-ups

- If a backend is ever needed for proto, that's a new, separately-scoped
  decision — not implied by this design.
- A future second preview environment repeats: a new `environments/*.tfvars`
  in `terraform-web-preview/`, one more entry in `fe-deploy-iam.tf`'s
  `fe_bucket_arns` list, one more branch in `deploy.yml`, one more GitHub
  Environment. No new Terraform code.
