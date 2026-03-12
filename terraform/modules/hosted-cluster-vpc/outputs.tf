# =============================================================================
# Hosted Cluster VPC Module - Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "IDs of private subnets for hosted cluster worker nodes"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "IDs of public subnets for load balancers"
  value       = aws_subnet.public[*].id
}

output "availability_zones" {
  description = "Availability zones used by the VPC subnets"
  value       = local.azs
}

output "nat_gateway_ids" {
  description = "IDs of NAT Gateways"
  value       = aws_nat_gateway.main[*].id
}

output "vpc_cidr" {
  description = "The CIDR block of the VPC"
  value       = aws_vpc.main.cidr_block
}

output "worker_security_group_id" {
  description = "ID of the security group for worker nodes"
  value       = aws_security_group.worker.id
}

output "hypershift_local_zone_id" {
  description = "Route53 hosted zone ID for {cluster}.hypershift.local PrivateLink DNS"
  value       = aws_route53_zone.hypershift_local.zone_id
}
