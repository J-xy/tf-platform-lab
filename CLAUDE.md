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

## Current status: bootstrap is DONE

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

## Locking: both mechanisms are on

`backend.tf` sets `dynamodb_table` AND `use_lockfile = true`, so every
operation takes two locks with the same lock ID:

- `s3://<bucket>/bootstrap/terraform.tfstate.tflock` — 242-byte JSON, deleted
  when the operation ends
- a DynamoDB item keyed on the state path — also removed at the end

`dynamodb_table` is deprecated on 1.11+ and emits a warning on every `init`.
That warning is expected, not a problem to fix.

The table also holds a **permanent** `<path>-md5` Digest item. It is not a
lock — it is the state checksum, rewritten on each apply. A `scan` returning
Count 1 between operations is healthy.

## Applying

Never run `terraform apply` or `destroy` without the user explicitly asking.
Applying `bootstrap/` creates billable AWS resources, and S3 buckets are
globally namespaced, so a bucket name has to be unique across all of AWS.

The local `terraform.tfstate` that `bootstrap/` produces is the real record of
those resources until it is migrated into the bucket it just created — treat it
as precious and never delete it.
