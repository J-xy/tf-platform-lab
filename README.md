# tf-platform-lab

Building a Terraform platform workflow from an empty AWS account up to
policy-gated CI — one stage at a time, with every non-obvious decision written
down and defended rather than copied from a tutorial.

**Stage 1 is complete and applied against real AWS infrastructure.** Stages 2–4
are planned and described below. The status table is honest; nothing here is
claimed as built before it is.

---

## The four stages

| Stage | Scope | What it demonstrates | Status |
|-------|-------|----------------------|--------|
| **1. Remote state backend** | S3 bucket + S3-native locking, applied with local state, then migrated into itself | Solving the bootstrap chicken-and-egg; state durability and locking as a designed property, not a default | ✅ **Done** |
| **2. Network stack** | A VPC/network stack using a second key in the same bucket | That the backend actually works as shared infrastructure — per-key locking, multiple states in one bucket | Planned |
| **3. CI gate** | `fmt` / `validate` / `plan` on every pull request | Terraform treated as reviewed code: no unplanned applies, no unformatted merges | Planned |
| **4. Policy as code** | `tflint`, `checkov`, OPA blocking merge on violations | Guardrails enforced by machine at review time, not by convention in a wiki | Planned |

Branch protection requiring a pull request is already enabled on `main`. It is
overkill for a solo repo today, and it is deliberate: Stage 3's CI gate is only
meaningful if merges genuinely flow through PRs, so the habit is set before the
tooling that depends on it.

---

## Stage 1 — what was actually built

The classic bootstrap problem: Terraform wants remote state, but the remote
state backend is itself infrastructure. `bootstrap/` resolves it by applying
with **local state**, then running `init -migrate-state` to move its own state
into the bucket it just created.

Six resources in `us-east-1`:

- **S3 bucket** — name composed at plan time from caller-identity account ID and
  region, since S3 names are globally unique
- **Versioning** — the recovery path for a corrupted or truncated state write
- **Server-side encryption** — SSE-S3 (AES256)
- **Public access block** — all four booleans
- **Lifecycle rules** — bounds otherwise-unlimited version growth
- **DynamoDB lock table** — created, then made redundant by Stage 1's own
  findings (see below)

State now lives at `s3://tf-state-<account>-us-east-1/bootstrap/terraform.tfstate`.

---

## Decisions, and the argument for each

The point of the lab is the reasoning, not the resource count.

**SSE-S3 over SSE-KMS.** KMS would require every principal running a plan to
hold `kms:Decrypt` on the key, and the key itself becomes another dependency
that must exist before state does — a second chicken-and-egg inside the first.
SSE-S3 has no key policy to manage and no additional cost. KMS earns its
complexity when you need an audit trail of decrypt calls or independent key
rotation; a bootstrap bucket needs neither.

**`prevent_destroy` on the bucket.** This bucket holds the state for every other
stack, so losing it means losing the record of what exists. The lifecycle guard
makes `terraform destroy` refuse until it is deliberately removed. That friction
is the feature.

**Composed bucket name over a hardcoded one.** `data.aws_caller_identity` +
region rather than `random_id`: it is deterministic, produces no diff on
re-apply, needs no extra provider, and — critically — can be re-derived from
nothing if state is ever lost before migration. A `random_id` suffix lives only
in state, which is precisely the thing you cannot rely on during a bootstrap.

**S3-native locking, no DynamoDB.** The lab created the lock table first, then a
deliberate contention test showed what actually refuses a concurrent apply:

```
Error: Error acquiring the state lock
  operation error S3: PutObject … StatusCode: 412
  api error PreconditionFailed
  ID:        01e86e89-a39b-46cb-d0fb-095d43f289e1
  Who:       jack@Mac-2641.lan
  Created:   2026-09-03 05:27:10 UTC
```

That 412 is `use_lockfile` — an atomic conditional `PutObject`, one API call, no
second service. DynamoDB existed to provide locking *before* S3 supported
conditional writes; `dynamodb_table` is deprecated on Terraform 1.11+. It was
dropped, and locking was re-tested afterward to confirm the guarantee survived
the change. Most bootstrap guides still tell you to create that table.

**Two lifecycle rules, not one.** AWS rejects `ExpiredObjectDeleteMarker` in an
expiration block that also carries day- or date-based conditions, so the
noncurrent-version rule and the delete-marker rule must be separate. The
expiry thresholds (30 days *and* 10 newer versions, ANDed) are deliberately
conservative: those noncurrent versions *are* the disaster-recovery story, and
expiring them aggressively would discard the property versioning exists to give.

The need was measured rather than assumed — after a handful of operations the
bucket already held 5 noncurrent versions and 3 delete markers, because every
lock cycle leaves both behind.

---

## Verification

Every claim above was checked against the AWS API rather than against
Terraform's own report of success:

| Check | Method |
|---|---|
| Encryption, versioning, public access block, tags | `aws s3api get-*` |
| Lock table schema and billing mode | `aws dynamodb describe-table` |
| Locking genuinely refuses concurrent applies | Two racing applies; caught the `.tflock` mid-flight |
| Lifecycle rules idempotent | Re-plan immediately after apply reports no changes |
| State survived backend changes | `state list` + `plan` after `init -reconfigure` |

---

## Layout

```
bootstrap/
  versions.tf     Terraform + provider constraints
  providers.tf    AWS provider, default_tags (owner / project / managed-by)
  main.tf         All six resources
  outputs.tf      Bucket, table, region — consumed by later stages
  backend.tf      S3 backend; added only after the first successful apply
CLAUDE.md         Working notes and operational gotchas
```

## Running it

```bash
cd bootstrap
terraform init
terraform plan      # free; requires AWS credentials
terraform apply     # creates billable resources (a few cents/year at this scale)
```

Credentials are IAM Identity Center (SSO) rather than long-lived access keys —
short-lived, expiring, nothing static written to disk.

---

## License

MIT — see [LICENSE](LICENSE).
