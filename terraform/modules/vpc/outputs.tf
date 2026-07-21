output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet ids."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet ids."
  value       = aws_subnet.private[*].id
}

output "azs" {
  description = "Availability zones in use."
  value       = local.azs
}

output "nat_public_ips" {
  description = "Public IPs of the NAT gateway(s), if any."
  value       = aws_eip.nat[*].public_ip
}
