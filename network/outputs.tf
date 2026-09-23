output "vpc_id" {
  value = module.baseline_vpc.vpc_id
}

output "public_subnet_ids" {
  value = module.baseline_vpc.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.baseline_vpc.private_subnet_ids
}

output "public_route_table_id" {
  value = module.baseline_vpc.public_route_table_id
}

output "private_route_table_ids" {
  value = module.baseline_vpc.private_route_table_ids
}