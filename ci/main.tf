# main.tf — Stage 3: the identity CI uses. No static credentials anywhere.
#
# GitHub Actions mints a short-lived OIDC token per run and trades it for AWS
# credentials via sts:AssumeRoleWithWebIdentity. Nothing long-lived is stored
# in the repository, so there is no key to leak, rotate, or revoke.

# ---------------------------------------------------------------------------
# 1. The identity provider — registers GitHub as a trusted token issuer.
#
#    No thumbprint_list. It used to be required and had to be hand-updated
#    whenever GitHub rotated its intermediate CA; AWS now validates this
#    provider's certificates natively, so pinning a thumbprint today buys
#    nothing and creates a future outage when it goes stale.
#
#    client_id_list is the audience the token must carry. sts.amazonaws.com is
#    what the official configure-aws-credentials action requests.
# ---------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]

  tags = {
    Name = "github-actions"
  }

  lifecycle {
    # AWS backfills a thumbprint for this well-known provider regardless of
    # what is sent, so any value Terraform holds here produces a permanent
    # diff. Left unmanaged deliberately: AWS validates this issuer's
    # certificates natively, so the stored value is AWS's business, not ours.
    ignore_changes = [thumbprint_list]
  }
}

# ---------------------------------------------------------------------------
# 2. Trust policy — WHO may assume the role.
#
#    The `sub` claim is the security boundary. GitHub issues IMMUTABLE subjects
#    that embed the numeric owner and repository IDs — the format is
#
#      repo:OWNER@<owner_id>/NAME@<repo_id>:<context>
#
#    NOT the repo:OWNER/NAME:<context> shown in most documentation. A policy
#    written against the documented form is rejected with
#    "Not authorized to perform sts:AssumeRoleWithWebIdentity", which reads
#    like a permissions problem rather than a string mismatch.
#
#    Pinning the IDs is stronger than pinning names: rename or transfer the
#    repo and the IDs follow it, so whoever claims the freed-up name inherits
#    nothing. Two contexts are allowed, and no others:
#
#      :pull_request        -> a PR run
#      :ref:refs/heads/main -> a run on main after merge
#
#    The `aud` condition must also be present. Without it the role would trust
#    tokens minted for a different audience entirely.
# ---------------------------------------------------------------------------
locals {
  # repo:J-xy@68347443/tf-platform-lab@1355558109
  repo_subject = "repo:${var.github_owner}@${var.github_owner_id}/${var.github_repo_name}@${var.github_repo_id}"
}

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "${local.repo_subject}:pull_request",
        "${local.repo_subject}:ref:refs/heads/main",
      ]
    }
  }
}

resource "aws_iam_role" "ci_plan" {
  name               = "github-actions-terraform-plan"
  description        = "Assumed by GitHub Actions to run terraform plan. Read-only apart from state locking."
  assume_role_policy = data.aws_iam_policy_document.trust.json

  # 1 hour. A plan across three stacks takes seconds; a long session is just a
  # longer window for a leaked token to be useful.
  max_session_duration = 3600
}

# ---------------------------------------------------------------------------
# 3. What the role may DO.
#
#    Reading resources is covered by the AWS-managed ViewOnlyAccess policy plus
#    plan_reads below. NOT ReadOnlyAccess: that grants data reads such as
#    s3:GetObject on every bucket in the account, which plan never needs.
#    That leaves one thing plan needs that is not read-only: the state lock.
#
#    A plan takes a lock like any other operation — without it, a plan run
#    while an apply is mid-flight reads half-written state and reports a diff
#    that never existed. So rather than passing -lock=false in CI, the role
#    gets write access to exactly the lock objects and nothing else: the
#    resource ARN is suffixed *.tflock, so this grant cannot touch a state
#    file even by accident.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "ListStateBucket"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket}"]
  }

  statement {
    sid       = "ReadState"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*"]
  }

  statement {
    sid       = "WriteLockObjectsOnly"
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket}/*.tflock"]
  }
}

resource "aws_iam_policy" "state_access" {
  name        = "tf-platform-lab-ci-state-access"
  description = "Read Terraform state; write only *.tflock lock objects."
  policy      = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy_attachment" "state_access" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = aws_iam_policy.state_access.arn
}

# ViewOnlyAccess reads metadata (Describe*/List*) but not configuration
# documents. plan_reads adds only the Get* calls a refresh of these three
# stacks makes that ViewOnlyAccess does not cover, each scoped to this
# project's ARNs rather than the account.
data "aws_iam_policy_document" "plan_reads" {
  # bootstrap: aws_s3_bucket and its sub-resources read every bucket setting on refresh; ViewOnlyAccess has none of them.
  statement {
    sid    = "StateBucketConfigRead"
    effect = "Allow"
    actions = [
      "s3:GetBucketAcl", "s3:GetBucketCORS", "s3:GetBucketLogging", "s3:GetBucketObjectLockConfiguration",
      "s3:GetBucketPolicy", "s3:GetBucketPublicAccessBlock", "s3:GetBucketRequestPayment", "s3:GetBucketTagging",
      "s3:GetBucketVersioning", "s3:GetBucketWebsite", "s3:GetAccelerateConfiguration",
      "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration",
    ]
    resources = [local.bucket_arn]
  }

  # ci: ViewOnlyAccess can list IAM but not Get a role, a policy document or the OIDC provider.
  statement {
    sid       = "CiIamRead"
    effect    = "Allow"
    actions   = ["iam:GetRole", "iam:GetPolicy", "iam:GetPolicyVersion", "iam:GetOpenIDConnectProvider"]
    resources = [local.role_prefix, local.policy_pfx, local.oidc_arn]
  }
}

resource "aws_iam_policy" "plan_reads" {
  name        = "tf-platform-lab-ci-plan-reads"
  description = "Config reads plan needs that ViewOnlyAccess lacks, scoped to this project."
  policy      = data.aws_iam_policy_document.plan_reads.json
}

resource "aws_iam_role_policy_attachment" "plan_reads" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = aws_iam_policy.plan_reads.arn
}

resource "aws_iam_role_policy_attachment" "view_only" {
  role       = aws_iam_role.ci_plan.name
  policy_arn = "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess"
}
