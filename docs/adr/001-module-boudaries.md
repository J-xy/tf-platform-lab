# ADR-001: Module Boundaries for baseline-vpc

**Status:** Accepted  
**Date:** 2026-09-25  
**Author:** Jack Xiong

## Context

The `network/` stack contained six inline resource types (VPC, public/private subnets, internet gateway, public route table, per-AZ private route tables, and route table associations). It worked, but it could only produce one VPC with one set of values. Standing up a second environment meant duplicating every resource block and keeping both copies in sync — a maintenance problem that scales linearly with the number of environments.

We needed dev and prod environments with different CIDRs, different name prefixes, and independent state, all running identical infrastructure logic.

## Decision

Extract `modules/baseline-vpc/` as a child module. Environment roots (`envs/dev/`, `envs/prod/`) source it from a pinned Git tag and pass environment-specific values through `terraform.tfvars`. Each root owns its own state key in the same S3 bucket.

Resources moved into the module:
- `aws_vpc`
- `aws_subnet` (public and private, keyed by AZ)
- `aws_internet_gateway`
- `aws_route_table` (one shared public, per-AZ private)
- `aws_route_table_association` (public and private)
- `data.aws_availability_zones`

Resources renamed to module convention (`main` → `this`) in the same change. Eight `moved` blocks added to the original root to preserve state on refactor — confirmed as safe no-ops on a stack that had never been applied.

## What we deliberately did not abstract

- **Provider configuration** stays in the root. The module declares a provider requirement (`~> 5.0`) but never configures region or credentials. That's the caller's job — it's what lets the same module deploy into different accounts without modification.
- **Backend configuration** stays in the root. State isolation is the caller's problem. Two roots writing to the same state key is the concurrent-apply race condition; the module has no business deciding where state lives.
- **Security groups** are not in this module. What ports are open depends on what runs in the VPC, which the VPC module shouldn't know about. A security group module or per-service config belongs one layer up.
- **NAT gateway** is declared as an input (`enable_nat`, default `false`) but not yet implemented. NAT costs ~$0.045/hr and must be an explicit opt-in, not a default that starts a billing meter on every apply.
- **Default tags** are handled via the provider's `default_tags` block in the root, not inside the module. The module merges caller-supplied `var.tags` onto each resource for anything environment- or team-specific.

## Versioning Policy

- **Tags follow semver.** `v0.1.0` is the first consumable version.
- **A breaking change bumps the major version.** Breaking means: removing or renaming a variable, removing an output, narrowing a validation range (e.g. changing `az_count` from 2–4 to 2–3), or changing a resource address (which would force a destroy/recreate in consumers' state).
- **A non-breaking change bumps the minor version.** Adding a variable with a default, adding an output, widening a validation range, or adding a resource are all non-breaking.
- **Environments upgrade by changing `?ref=` in their module source.** Prod never moves until the new tag has been applied and destroyed successfully in dev. This is manual and deliberate — no automatic version floating.

## Consequences

**Easier:**
- New environments are a five-file root (`main.tf`, `backend.tf`, `providers.tf`, `variables.tf`, `terraform.tfvars`) with zero resource blocks.
- Module logic is tested once (`terraform test` with `mock_provider`) and consumed everywhere.
- A bug fix to subnet logic ships to every environment on the next tag bump, not through N separate edits.

**Harder:**
- Any change to the module interface requires checking every consumer. With two environments this is trivial; at ten it needs automation (a CI job that plans every root against a candidate tag before it's released).
- The module is opinionated about subnet layout (public + private per AZ, /24s carved from a /16). A team that needs a different topology can't use it without forking or adding variables — and adding variables to satisfy one team's edge case is how modules become unusable for