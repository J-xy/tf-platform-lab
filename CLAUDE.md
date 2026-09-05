# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

A personal Terraform learning lab. The current (and only) piece of work is
`bootstrap/` — the standard "chicken and egg" step that provisions the remote
state backend itself: an S3 bucket for state plus a DynamoDB table for state
locking. Because it creates the backend, `bootstrap/` is applied with **local
state** and has no `backend` block of its own.

Git repo, no remote. No CI, no test suite, no module registry.

## Working style — read this first

`bootstrap/main.tf` is a checklist the user wrote for themselves, phrased as
prompts ("in your own words first", "why?", "be ready to defend `~>` vs `>=`").
It is deliberately unimplemented. The goal here is the user learning Terraform,
not a finished artifact.

So: **do not fill in the empty files unless asked to.** When the user is working
through a resource, prefer explaining the concept, reviewing what they wrote, or
pointing at the relevant provider docs over writing the HCL for them. If they do
ask for an implementation, give it — but keep their comment scaffolding intact.

The self-quiz hints already in the file are the intended curriculum:

- versioning on the state bucket → recovery from state corruption
- `aws_dynamodb_table.hash_key` **must** be literally `LockID` — Terraform's
  lock protocol requires that exact attribute name
- `billing_mode = "PAY_PER_REQUEST"` — a lock table sees negligible traffic
- `aws_s3_bucket_public_access_block` → set all four booleans, not a subset

## Layout

```
bootstrap/
  versions.tf          terraform + provider version constraints (the only file with content)
  providers.tf         empty — provider "aws" block (region) goes here
  main.tf              resource checklist, not yet implemented
  variables.tf         empty
  outputs.tf           empty
  backend.tf           empty — holds the backend "s3" block at migration time (stage 2)
  .terraform.lock.hcl  provider checksums; committed on purpose
```

Files are split by role (`versions` / `variables` / `main` / `outputs`) rather
than kept in one file. Keep that convention when adding to a directory, and give
any new stack the same four-file shape.

## Version constraints

`versions.tf` pins `required_version = "~> 1.5"` and `hashicorp/aws ~> 5.0`.
Locally installed Terraform is **1.15.8**, which satisfies `~> 1.5`
(`>= 1.5.0, < 2.0.0`). If a constraint is tightened to `~> 1.5.0`, the local
binary will stop working — flag that rather than silently loosening it.

## Commands

```bash
cd bootstrap
terraform init              # already run; aws provider v5.100.0 pinned in the lock file
terraform fmt -recursive     # run before considering any HCL change done
terraform validate           # offline, no credentials needed
terraform plan
```

`init`, `validate`, and `fmt` need no AWS credentials. `plan` and `apply` do —
and **this machine has none configured**: no `~/.aws/`, no `AWS_PROFILE` /
`AWS_ACCESS_KEY_ID` in the environment, and no AWS CLI installed. `plan` will
fail at provider configuration until that is fixed. Don't reach for anything
hitting the AWS API without checking with the user first.

## Stage 5: drift detection (DONE)

`.github/workflows/drift.yml` — daily cron plus `workflow_dispatch`.

- Runs `plan -detailed-exitcode` on all three stacks. 0 = match, 2 = drift,
  1 = error; all three are handled separately. Every stack is checked even
  after one drifts.
- Maintains ONE issue labelled `drift`: comments on the existing open issue
  rather than opening new ones, and closes it when everything matches again.
  Do not "simplify" this into create-every-run — a new issue per day is how
  drift alerting gets ignored.
- Needs `issues: write` on top of the usual `id-token: write` / `contents: read`.
- No IAM change: a scheduled run's OIDC sub is `ref:refs/heads/main`, already
  allowed by the Stage 3 trust policy.
- Verified by creating real drift (a stray tag on the VPC via AWS CLI),
  confirming exit code 2, then reverting with apply.

## Stage 4: policy scanning (DONE)

- `policy` job in CI runs tflint + `trivy config`. No AWS credentials — the
  scanners read HCL, so the job runs in parallel with plan.
- Suppressions live in `.trivyignore.yaml`, each with a written justification.
  Do NOT add an entry without a reason a reviewer could argue with; fix the
  finding instead.
  - `AVD-AWS-0132` (S3 without CMK) — permanent, deliberate SSE-S3 choice.
  - `AVD-AWS-0178` (VPC flow logs) — deferred with `expiredAt: 2027-03-01`.
- **tfsec is not used and should not be added.** It is in maintenance mode;
  Aqua directs users to Trivy, which has the same engine. Checkov is also
  deliberately absent — it overlaps Trivy heavily.
- The DynamoDB lock table was DELETED in this stage. It had been dead since
  `use_lockfile` replaced it. `bootstrap/outputs.tf` no longer exports
  `state_lock_table_name`.

## Stage 3: ci/ (DONE)

Applied 2026-09-04. GitHub OIDC federation — CI holds no static credentials.

- Role `arn:aws:iam::964291633585:role/github-actions-terraform-plan`
- **GitHub issues IMMUTABLE subject claims.** The real `sub` is
  `repo:J-xy@68347443/tf-platform-lab@1355558109:pull_request`, embedding the
  numeric owner and repo IDs — NOT the `repo:OWNER/NAME:context` form that most
  documentation still shows. A policy written against the documented form is
  rejected with `Not authorized to perform sts:AssumeRoleWithWebIdentity`,
  which reads like a permissions problem and is a string mismatch. Trust is
  scoped to two contexts only: `:pull_request` and `:ref:refs/heads/main`.
- `thumbprint_list` is under `ignore_changes`. AWS backfills a thumbprint for
  this provider whatever you send, so managing it is a permanent diff.
- Permissions: managed `ReadOnlyAccess` plus a policy granting `s3:PutObject`
  and `s3:DeleteObject` only on `*.tflock`. Plan keeps its lock; the role still
  cannot write state.
- The role ARN is hardcoded in `.github/workflows/terraform.yml` under
  `env.AWS_ROLE_ARN`. If `ci/` is ever recreated, update it there too.

**Ordering trap:** the workflow references the role by ARN, so `ci/` must be
applied before the workflow ever runs, or CI fails at role assumption.

The permission set needed `IAMFullAccess` for this stage. Note the asymmetry:
`terraform plan` on `ci/` succeeded WITHOUT any IAM permissions, because every
resource was a create and `aws_iam_policy_document` renders locally. Only
`apply` needed them.

## Stage 2: network/ (DONE)

Applied 2026-09-03. VPC `vpc-0cdc7c1483f0fad89`, `10.0.0.0/16`, us-east-1.
State key `network/terraform.tfstate` in the Stage 1 bucket.

- 13 resources: VPC, 2 public + 2 private subnets across us-east-1a/1b, IGW,
  1 shared public route table, 1 private route table **per AZ**, 4 associations
- No NAT gateway — private subnets have no egress, deliberately. Everything
  here is free of hourly charges.
- Subnets use `for_each` keyed by AZ name, so addresses are
  `aws_subnet.public["us-east-1a"]`. Do not convert to `count`.
- `data.aws_availability_zones` is filtered to `available`; AZs are never
  hardcoded.

**The permission set needed widening for this stage.** `s3-dynamoDB-Admin` had
no EC2 access at all; `AmazonVPCFullAccess` was attached in the console. Any
future stage touching a new service will hit the same wall — the symptom is
`UnauthorizedOperation` on a Describe call, not a Terraform error.

Verified: concurrent applies against `bootstrap/` and `network/` both exit 0
with no lock contention, confirming the lock is per key, not per bucket.

## Stage 1: bootstrap is DONE

Both stages are complete as of 2026-09-02. State is remote.

- Account `964291633585`, region `us-east-1`
- Bucket `tf-state-964291633585-us-east-1`, key `bootstrap/terraform.tfstate`
- Lock table `tf-state-lock`
- `bootstrap/terraform.tfstate` on disk is a 0-byte husk; the real state is in
  S3. `terraform.tfstate.backup` holds the pre-migration copy (serial 6) —
  keep it.

Credentials are IAM Identity Center SSO, `default` profile in `~/.aws/config`,
sso instance in **us-east-2** (the resources are us-east-1 — the two regions
differ on purpose). Session expiry shows up as `token has expired`; fix with
`aws sso login` in a real terminal.

## Interactive commands need a real TTY

`aws configure sso` and `aws sso login` fail under the `!` prefix with
`Input is not a terminal`. They must be run in Terminal.app. Same for
`terraform apply`'s approval prompt — use `-auto-approve` after showing the
user a plan, and `init -migrate-state -force-copy` for migration.

## Locking: S3-native only

`backend.tf` uses `use_lockfile = true` and nothing else. The lock is a
conditional `PutObject` of `bootstrap/terraform.tfstate.tflock`; a second
concurrent operation is refused with `S3: PutObject ... 412
PreconditionFailed` and the error prints the holder's `Who`/`Created`.

`dynamodb_table` was dropped in 69fce94 — deprecated on 1.11+, and redundant
once S3 gained conditional writes.

**The DynamoDB table still exists and is still managed by `main.tf`, but
nothing uses it.** It holds one orphaned `<path>-md5` digest item left over
from when the backend was configured against it; Terraform will never touch
that item again. Removing `aws_dynamodb_table.state_lock` from `main.tf` is
safe whenever the user wants it — but it is a destroy, so ask first.

## Applying

Never run `terraform apply` or `destroy` without the user explicitly asking.
Applying `bootstrap/` creates billable AWS resources, and S3 buckets are
globally namespaced, so a bucket name has to be unique across all of AWS.

The local `terraform.tfstate` that `bootstrap/` produces is the real record of
those resources until it is migrated into the bucket it just created — treat it
as precious and never delete it.
