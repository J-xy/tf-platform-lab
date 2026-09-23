output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Map of AZ name → public subnet ID."
  value       = { for az, s in aws_subnet.public : az => s.id }
}

output "private_subnet_ids" {
  description = "Map of AZ name → private subnet ID."
  value       = { for az, s in aws_subnet.private : az => s.id }
}

output "public_route_table_id" {
  description = "ID of the shared public route table."
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Map of AZ name → private route table ID."
  value       = { for az, rt in aws_route_table.private : az => rt.id }
}