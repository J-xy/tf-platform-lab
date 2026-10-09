# OIDC negative tests

The trust policies in `ci/` say who may assume each role. This file records
attempts to assume them from positions that should fail, and the evidence that
they did. A positive test (main can plan, prod can apply) proves the pipeline
works. Only a negative test proves the boundary holds.

Last run: 2026-10-05, workflow `neg-oidc` on branch `neg/assume-apply`,
run `37380120461`.

## Precondition: prove the role exists before trusting a denial

STS returns the same error for "this subject is not trusted" and "this role
does not exist":

```
Not authorized to perform sts:AssumeRoleWithWebIdentity
```

If the OIDC provider itself is missing, the error changes to an
`InvalidIdentityToken` complaining that no provider is registered for the
issuer. Neither error proves the trust policy did anything.

The 2026-09-30 teardown deleted the provider and both roles. A negative test
run against that account would have "passed" while testing nothing. Before
every run of this suite:

```bash
aws iam get-open-id-connect-provider \
  --open-id-connect-provider-arn arn:aws:iam::964291633585:oidc-provider/token.actions.githubusercontent.com
aws iam get-role --role-name github-actions-terraform-apply  --query Role.Arn
aws iam get-role --role-name github-actions-terraform-plan   --query Role.Arn
```

Verified before the 2026-10-05 run: both roles returned their ARNs, and STS
answered `AccessDenied` rather than `InvalidIdentityToken`, so the provider
was registered.

## What each role trusts

Both roles require `aud = sts.amazonaws.com` and an exact `sub` match
(`StringEquals`, no wildcards). The subject prefix is the immutable form,
`repo:J-xy@68347443/tf-platform-lab@1355558109`.

| Role | Accepted `sub` suffixes |
| --- | --- |
| `github-actions-terraform-plan` | `:pull_request`, `:ref:refs/heads/main` |
| `github-actions-terraform-apply` | `:environment:prod` |

The apply subject does not encode a branch. GitHub replaces the ref with the
environment name whenever a job declares `environment:`, so the trust policy
cannot tell main from a feature branch. That job falls to the `prod`
environment's settings: deployment branches limited to protected branches
(today that means `main`, the only branch with a protection rule), plus a
required reviewer. Test 3 exists because of this.

## Results

| # | Attacker position | `sub` presented | Expected | Result |
| --- | --- | --- | --- | --- |
| 1 | Push to `neg/assume-apply`, assume apply role | `…:ref:refs/heads/neg/assume-apply` | STS denies | **Pass**: denied by STS |
| 2 | Same branch, assume plan role | `…:ref:refs/heads/neg/assume-apply` | STS denies (plan trusts PR and main only) | **Pass**: denied by STS |
| 3 | Feature-branch job declares `environment: prod` | none minted | GitHub refuses to start the job | **Pass**: rejected before a runner was assigned |
| 4 | Apply job on main, approval withheld | none minted | Job waits; no token is minted | **Pass**: held by GitHub, zero STS calls |

### Tests 1 and 2: feature branch → apply role, plan role

Decoded token claims from the t1 job (payload only, never the raw token):

```
"sub": "repo:J-xy@68347443/tf-platform-lab@1355558109:ref:refs/heads/neg/assume-apply"
```

Both jobs failed at the assume step with the same error:

```
t1  2026-10-05T22:07:41Z  ##[error]Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
t2  2026-10-05T22:06:06Z  ##[error]Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

CloudTrail recorded every attempt as `AssumeRoleWithWebIdentity` with
`errorCode: AccessDenied`. The `principalId` carries the provider, audience
and full subject:

```
arn:aws:iam::964291633585:oidc-provider/token.actions.githubusercontent.com:sts.amazonaws.com:repo:J-xy@68347443/tf-platform-lab@1355558109:ref:refs/heads/neg/assume-apply
```

Query used:

```bash
aws cloudtrail lookup-events --region us-east-1 \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --start-time 2026-10-05T22:04:00Z --end-time 2026-10-05T22:10:00Z --output json |
jq '.Events[].CloudTrailEvent | fromjson | {eventTime, errorCode, role: .requestParameters.roleArn, principal: .userIdentity.principalId}'
```

Two things the run showed that the test plan did not predict:

1. **Two jobs produced about 24 denials, not 2.** `configure-aws-credentials`
   retries a failed assume with backoff. t2 started at 22:04:52 and gave up
   at 22:06:06, and t1 started at 22:05:28 and gave up at 22:07:41. Their
   retries overlap between 22:05:28 and 22:06:06, so per-job counts can't be
   recovered from CloudTrail alone. For detection this is useful: a probe
   against these roles produces a burst of `AccessDenied` from one subject,
   not a single event.
2. **CloudTrail does not record which role was requested.**
   `requestParameters.roleArn` was null on every denied event. The subject
   says who tried; nothing in the event says what they tried to assume. A
   detection keyed on role ARN would miss these. Key it on `principalId`
   instead, and alert on any subject outside the three legitimate contexts
   (`:pull_request`, `:ref:refs/heads/main`, `:environment:prod`).

### Test 3: claiming the prod environment from a branch

This is the test that matters most. If the deployment-branch rule were
missing, GitHub would mint a token with `sub = …:environment:prod` from a
feature branch, and STS would accept it, because the trust policy is
working as written. The failure would sit entirely in GitHub settings, with
nothing in `ci/` to show it.

The job (`t3-branch-claims-prod`, job `111999640496`) never got a runner. It
has no steps, not even "Set up job", and no log. GitHub's annotations:

```
failure  Branch "neg/assume-apply" is not allowed to deploy to prod due to environment protection rules.
failure  The deployment was rejected or didn't satisfy other protection rules.
```

No runner means no `ACTIONS_ID_TOKEN_REQUEST_*` variables, so no token
existed to present. CloudTrail confirms this: every denied event in the window
carries the `:ref:refs/heads/neg/assume-apply` subject, and none carries
`:environment:prod`.

### Test 4: an unapproved apply never receives credentials

The evidence for this one is an absence, so it needs a control to show the
query could have seen something.

Merging PR #20 at 2026-10-05T22:26:07Z triggered run `37382450838`. The
three `plan` jobs ran, and `apply (bootstrap)` (job `112007725132`) stopped
at the `prod` gate:

```
{ "name": "apply (bootstrap)", "status": "waiting", "steps": [] }
```

GitHub's pending-deployments API showed what it was holding:

```
{ "env": "prod", "reviewers": ["J-xy"], "wait_timer": 0 }
```

The run was cancelled without approval. CloudTrail for 22:26–22:40 UTC:

```
2026-10-05T22:26:25Z  errorCode: null  …:ref:refs/heads/main
2026-10-05T22:26:25Z  errorCode: null  …:ref:refs/heads/main
2026-10-05T22:26:28Z  errorCode: null  …:ref:refs/heads/main
```

The three successful `:ref:refs/heads/main` events are the plan jobs
assuming the plan role. They are the control: they prove the query covered
the window and that CloudTrail had ingested it. No event carries
`:environment:prod`. The apply job held a place in the queue but never got a
runner, so it never requested a token, and STS never saw it.

Gotcha found while collecting this: an empty result from a query filtered to
`environment:prod` looks identical whether the gate held or CloudTrail hasn't
ingested the window yet. Run it unfiltered first and confirm the plan events
are present.

## Sep 4: the subject that didn't match the docs

### What happened

`ci/` was first applied on 2026-09-04. The plan role's trust policy was
written against the subject format in GitHub's and AWS's documentation:

```
repo:J-xy/tf-platform-lab:pull_request
```

The token GitHub actually minted for the PR run carried the immutable form,
which embeds the numeric owner and repository IDs:

```
repo:J-xy@68347443/tf-platform-lab@1355558109:pull_request
```

`StringEquals` compares whole strings, so the condition failed and
`configure-aws-credentials` reported:

```
Could not assume role with OIDC: Not authorized to perform sts:AssumeRoleWithWebIdentity
```

This is the same error the 2026-10-05 negative tests produced on purpose. On
Sep 4 it was an accident, and it looked like a permissions problem.

The immutable format was GitHub's default for this repo, not an opt-in.
GitHub announced immutable subject claims on 2026-04-23 as opt-in for
existing repositories, and made them mandatory for every repository created
after 2026-07-15. This repo was created after that date, so its subject was
immutable from the first run. The repo's OIDC customization confirms it:

```
gh api repos/J-xy/tf-platform-lab/actions/oidc/customization/sub
{ "use_default": true, "use_immutable_subject": true,
  "sub_claim_prefix": "repo:J-xy@68347443/tf-platform-lab@1355558109" }
```

The repo's creation date confirms it:

```
gh repo view J-xy/tf-platform-lab --json createdAt
{ "createdAt": "2026-09-03T05:40:48Z" }
```

2026-09-03 is after the 2026-07-15 cutover.

So the documentation was not wrong when it was written. It was stale for
any repo created after the cutover, and most tutorials and AWS examples
still show the name-based form. The practical lesson: a trust policy copied
from documentation is a guess about the token's shape, and the decoded
token is the fact.

### Why it was hard to find

The error describes a permissions problem. Nothing in it says "your subject
string doesn't match." The natural next moves are checking the role's
permissions policy, the provider's audience, and the `id-token: write`
permission, and none of those were wrong. The fix came from decoding the
token's payload and reading the `sub` claim directly, instead of trusting the
documented format.

Lesson: when a federated assume fails, dump the claims first. The trust
policy is a string comparison, and the only way to debug a string comparison
is to look at both strings.

### Why pinning IDs beats pinning names

A name-based subject trusts whoever holds the name `J-xy/tf-platform-lab`.
Names are reassignable. If the repo is renamed or transferred, or the account
is renamed, the old name becomes available to someone else. Their workflows
would mint tokens whose `sub` matches a name-pinned policy exactly, and AWS
would hand them this account's role. This is the repo-jacking pattern applied
to cloud federation.

The numeric IDs follow the repository, not the name. If someone claims the
freed name, they get a new `repository_id`, and the policy rejects them. The
cost is readability. The policy no longer reads cleanly, so the IDs are
documented in `ci/main.tf` and derived from variables, not hard-coded twice.
