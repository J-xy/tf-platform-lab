# outputs.tf — what a consumer of this stack actually needs, via
# terraform_remote_state or otherwise. Not everything: just the handles.

output "vpc_id" {
  description = "ID of the network VPC."
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "CIDR of the VPC, echoed for consumers writing security rules."
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs, keyed by availability zone."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "private_subnet_ids" {
  description = "Private subnet IDs, keyed by availability zone."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "availability_zones" {
  description = "AZs this stack was built across."
  value       = local.azs
}
