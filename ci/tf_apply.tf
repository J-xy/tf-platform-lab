# tf_apply.tf — Stage 5: the role that applies. Separate from the plan role on
# purpose: plan runs on every PR, apply runs only after merge and approval.
#
# FIRST CREATION IS MANUAL. This role cannot create itself through CI, so the
# first `terraform apply` of ci/ runs locally with human credentials. After
# that, CI manages it like everything else.

# ---------------------------------------------------------------------------
# 1. Trust. Only a job that declares `environment: prod` receives this subject.
#    PR runs get :pull_request and main pushes get :ref:refs/heads/main, so the
#    plan role's contexts can never match here.
#
#    The subject does NOT encode the branch. What stops a PR from adding
#    `environment: prod` to a job is the GitHub Environment itself:
#    deployment branches = main only, required reviewer = me. That setting is
#    part of this control, not an optional extra.
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "apply_trust" {
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
      values   = ["${local.repo_subject}:environment:prod"]
    }
  }
}

resource "aws_iam_role" "ci_apply" {
  name                 = "github-actions-terraform-apply"
  description          = "Assumed by GitHub Actions to run terraform apply on main, behind the prod environment."
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

# ---------------------------------------------------------------------------
# 2. Permissions, scoped to what bootstrap, network and ci actually manage.
# ---------------------------------------------------------------------------
locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_arn  = "arn:aws:s3:::${var.state_bucket}"
  role_prefix = "arn:aws:iam::${local.account_id}:role/github-actions-terraform-*"
  policy_pfx  = "arn:aws:iam::${local.account_id}:policy/tf-platform-lab-*"
  oidc_arn    = aws_iam_openid_connect_provider.github.arn
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "apply_permissions" {
  # State: read/write every stack's state and create/release *.tflock (lock release is a DeleteObject).
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${local.bucket_arn}/*"]
  }

  # bootstrap: read every bucket setting the provider refreshes, write only the ones main.tf configures. No DeleteBucket, backing prevent_destroy.
  statement {
    sid = "StateBucketConfig"
    actions = [
      "s3:ListBucket", "s3:CreateBucket",
      "s3:GetBucket*", "s3:GetAccelerateConfiguration", "s3:GetEncryptionConfiguration",
      "s3:GetLifecycleConfiguration", "s3:GetReplicationConfiguration",
      "s3:PutBucketVersioning", "s3:PutEncryptionConfiguration",
      "s3:PutBucketPublicAccessBlock", "s3:PutLifecycleConfiguration", "s3:PutBucketTagging",
    ]
    resources = [local.bucket_arn]
  }

  # network: everything baseline-vpc creates. EC2 has no resource-level ARNs for most of these, so scope is by action list.
  statement {
    sid = "VpcNetworking"
    actions = [
      "ec2:Describe*",
      "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
      "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
      "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
      "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
      "ec2:CreateRouteTable", "ec2:DeleteRouteTable",
      "ec2:CreateRoute", "ec2:DeleteRoute", "ec2:ReplaceRoute",
      "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
      "ec2:CreateTags", "ec2:DeleteTags",
    ]
    resources = ["*"]
  }

  # ci: the GitHub OIDC provider. One ARN, nothing else.
  statement {
    sid       = "OidcProvider"
    actions   = ["iam:*OpenIDConnectProvider*"]
    resources = [local.oidc_arn]
  }

  # ci: CI roles and their policies, limited by name prefix so unrelated roles are out of reach.
  statement {
    sid = "CiRolesAndPolicies"
    actions = [
      "iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy", "iam:TagRole", "iam:UntagRole",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
      "iam:DetachRolePolicy",
      "iam:GetPolicy", "iam:GetPolicyVersion", "iam:ListPolicyVersions",
      "iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
      "iam:TagPolicy", "iam:UntagPolicy",
    ]
    resources = [local.role_prefix, local.policy_pfx]
  }

  # ci: attach only this project's policies plus ViewOnlyAccess (the plan role's base). No other AWS-managed policy is attachable.
  statement {
    sid       = "AttachApprovedPoliciesOnly"
    actions   = ["iam:AttachRolePolicy"]
    resources = [local.role_prefix]

    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values = [
        local.policy_pfx,
        # job-function/ is part of the ARN; without it the condition never matches.
        "arn:aws:iam::aws:policy/job-function/ViewOnlyAccess",
      ]
    }
  }

  # RESIDUAL RISK, accepted: CreatePolicy / CreatePolicyVersion on
  # tf-platform-lab-* lets this role write a policy with any content and attach
  # it, so the allow-list above stops AdministratorAccess by name, not admin by
  # effect. A role that manages its own IAM cannot be fully prevented from
  # escalating without a permissions boundary. The control is the prod
  # environment: every apply is a reviewed merge plus a manual approval.
}

resource "aws_iam_policy" "apply" {
  name        = "tf-platform-lab-ci-apply"
  description = "Manage the bootstrap, network and ci stacks. Nothing else."
  policy      = data.aws_iam_policy_document.apply_permissions.json
}

resource "aws_iam_role_policy_attachment" "apply" {
  role       = aws_iam_role.ci_apply.name
  policy_arn = aws_iam_policy.apply.arn
}
