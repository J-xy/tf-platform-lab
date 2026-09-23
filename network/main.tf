# main.tf — Stage 2: network. Now calls modules/baseline-vpc.

module "baseline_vpc" {
  source = "../modules/baseline-vpc"

  name_prefix = var.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count
  tags        = { environment = "dev" }
}

# ---------------------------------------------------------------------------
# Moved blocks: preserves state if this stack was ever applied. If it was
# never applied, these are no-ops — Terraform checks for a matching state
# address and does nothing when none exists.
# ---------------------------------------------------------------------------

moved {
  from = aws_vpc.main
  to   = module.baseline_vpc.aws_vpc.this
}

moved {
  from = aws_internet_gateway.main
  to   = module.baseline_vpc.aws_internet_gateway.this
}

moved {
  from = aws_subnet.public
  to   = module.baseline_vpc.aws_subnet.public
}

moved {
  from = aws_subnet.private
  to   = module.baseline_vpc.aws_subnet.private
}

moved {
  from = aws_route_table.public
  to   = module.baseline_vpc.aws_route_table.public
}

moved {
  from = aws_route_table.private
  to   = module.baseline_vpc.aws_route_table.private
}

moved {
  from = aws_route_table_association.public
  to   = module.baseline_vpc.aws_route_table_association.public
}

moved {
  from = aws_route_table_association.private
  to   = module.baseline_vpc.aws_route_table_association.private
}

