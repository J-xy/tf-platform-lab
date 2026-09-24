# tests/baseline_vpc.tftest.hcl
#
# mock_provider means no real AWS calls happen — the provider returns
# fabricated-but-plausible values for anything marked "computed" in the
# resource schema (ids, arns, etc.), so `plan` and `apply` inside a test
# run succeed without ever touching an account. This costs nothing and
# needs no credentials.

mock_provider "aws" {}

# The module calls data "aws_availability_zones" "available" and then
# slice()s var.az_count entries out of .names. A mocked data source with
# no override returns an arbitrary/empty result, and slice() throws if
# fewer entries exist than requested. This override pins four real-looking
# AZ names so every run — including az_count = 4 — has enough to slice,
# and so the count is deterministic instead of provider-dependent.
override_data {
  target = data.aws_availability_zones.available
  values = {
    names = ["us-east-1a", "us-east-1b", "us-east-1c", "us-east-1d"]
  }
}

# ---------------------------------------------------------------------------
# Positive case: valid inputs produce the subnet count you expect.
# ---------------------------------------------------------------------------
run "valid_inputs_create_expected_subnets" {
  command = plan

  variables {
    name_prefix = "test-lab"
    vpc_cidr    = "10.0.0.0/16"
    az_count    = 2
  }

  assert {
    condition     = length(aws_subnet.public) + length(aws_subnet.private) == var.az_count * 2
    error_message = "expected az_count * 2 total subnets"
  }
}

# ---------------------------------------------------------------------------
# Negative case: a CIDR that isn't /16 must fail validation at plan time.
# ---------------------------------------------------------------------------
run "rejects_non_16_cidr" {
  command = plan

  variables {
    name_prefix = "test-lab"
    vpc_cidr    = "10.0.0.0/24" # deliberately wrong: not a /16
    az_count    = 2
  }

  expect_failures = [
    var.vpc_cidr,
  ]
}

# ---------------------------------------------------------------------------
# Negative case: az_count outside the allowed 2-4 range.
# ---------------------------------------------------------------------------
run "rejects_az_count_out_of_range" {
  command = plan

  variables {
    name_prefix = "test-lab"
    vpc_cidr    = "10.0.0.0/16"
    az_count    = 5 # allowed range is 2-4
  }

  expect_failures = [
    var.az_count,
  ]
}

# ---------------------------------------------------------------------------
# Negative case: name_prefix that breaks the regex (uppercase not allowed).
# ---------------------------------------------------------------------------
run "rejects_invalid_name_prefix" {
  command = plan

  variables {
    name_prefix = "Test-Lab" # uppercase letters violate ^[a-z0-9-]{3,32}$
    vpc_cidr    = "10.0.0.0/16"
    az_count    = 2
  }

  expect_failures = [
    var.name_prefix,
  ]
}
