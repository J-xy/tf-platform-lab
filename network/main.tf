# main.tf — Stage 2: network. Free tier only, no NAT gateway.

# ---------------------------------------------------------------------------
# 1. Availability zones.
#    Filtered to "available" because an AZ can exist in a region yet be closed
#    to your account — usually capacity. Unfiltered, you can plan a subnet into
#    a zone that refuses to create it.
#
#    Not hardcoded, because AZ *names* are per-account aliases: us-east-1a in
#    this account is a different physical zone from us-east-1a in another.
#    slice() takes only as many as az_count asks for.
# ---------------------------------------------------------------------------
data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)
}

# ---------------------------------------------------------------------------
# 2. The VPC.
#    enable_dns_support   = the VPC resolver at x.x.x.2 answers at all.
#    enable_dns_hostnames = instances additionally get DNS *names*.
#    Both default false-ish on a non-default VPC; VPC endpoints and most
#    service discovery need hostnames, and the failure mode is a name that
#    simply does not resolve, which reads like a networking bug rather than
#    a missing flag.
# ---------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name_prefix}-vpc"
  }
}

# ---------------------------------------------------------------------------
# 3. Subnet plan.
#    Built as a map keyed by AZ name so every subnet's state address is
#    aws_subnet.public["us-east-1a"] rather than [0]. Identity is then tied to
#    the AZ, not to a position: drop an AZ later and only that subnet is
#    destroyed, instead of every subnet after it being renumbered.
#
#    cidrsubnet(10.0.0.0/16, 8, n) carves /24s. Public gets n = 0,1,2..;
#    private gets n + 128, so the two ranges cannot collide as az_count grows.
# ---------------------------------------------------------------------------
locals {
  subnets = {
    for idx, az in local.azs : az => {
      public_cidr  = cidrsubnet(var.vpc_cidr, 8, idx)
      private_cidr = cidrsubnet(var.vpc_cidr, 8, idx + 128)
    }
  }
}

# ---------------------------------------------------------------------------
# 4. Public subnets.
#    map_public_ip_on_launch = true: anything launched here gets a public IP
#    automatically. Defensible for a public tier, and the argument against is
#    that it makes exposure the default rather than a decision. Left on here
#    because that is what "public subnet" is for; a workload tier would not.
# ---------------------------------------------------------------------------
resource "aws_subnet" "public" {
  for_each = local.subnets

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = each.value.public_cidr
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.name_prefix}-public-${each.key}"
    tier = "public"
  }
}

# ---------------------------------------------------------------------------
# 5. Private subnets.
#    Identical shape. Nothing here marks them private — there is no such flag.
#    They are private solely because their route table (7) has no 0.0.0.0/0.
# ---------------------------------------------------------------------------
resource "aws_subnet" "private" {
  for_each = local.subnets

  vpc_id            = aws_vpc.main.id
  availability_zone = each.key
  cidr_block        = each.value.private_cidr

  tags = {
    Name = "${var.name_prefix}-private-${each.key}"
    tier = "private"
  }
}

# ---------------------------------------------------------------------------
# 6. Internet gateway. One per VPC, attached by vpc_id.
#    Creating it does nothing on its own — an IGW only matters once a route
#    table points at it (7). Attached-but-unrouted is a common dead end.
# ---------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-igw"
  }
}

# ---------------------------------------------------------------------------
# 7. Public route table. One shared table: every public subnet wants the same
#    default route, so per-AZ tables would be duplication with no benefit.
#
#    The route is an inline block. The alternative is a separate aws_route
#    resource — both work, but mixing them for the SAME table makes Terraform
#    and AWS fight over ownership, producing a permanent diff.
# ---------------------------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.name_prefix}-public-rt"
  }
}

# ---------------------------------------------------------------------------
# 8. Private route tables — one PER AZ, unlike the public one.
#    They are identical and empty today, which looks like waste. The reason is
#    forward compatibility: a NAT gateway is a per-AZ resource, so the moment
#    one is added each AZ's private subnet must route to the NAT in its own AZ.
#    Building one shared table now would mean destroying and recreating routing
#    later. Route tables are free, so the option is worth keeping open.
#
#    No 0.0.0.0/0 route at all — that is precisely what "no NAT" means. The
#    local route within the VPC CIDR is implicit and must not be declared.
# ---------------------------------------------------------------------------
resource "aws_route_table" "private" {
  for_each = local.subnets

  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.name_prefix}-private-rt-${each.key}"
  }
}

# ---------------------------------------------------------------------------
# 9. Associations. Separate resources from the tables themselves, and the step
#    that is easy to skip: without them subnets silently fall back to the VPC's
#    main route table, which appears to work until it very much does not.
# ---------------------------------------------------------------------------
resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
