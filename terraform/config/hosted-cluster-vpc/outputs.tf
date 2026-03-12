# =============================================================================
# Hosted Cluster VPC Configuration - Outputs
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC"
  value       = module.hosted_cluster_vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of private subnets for hosted cluster worker nodes"
  value       = module.hosted_cluster_vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "IDs of public subnets for load balancers"
  value       = module.hosted_cluster_vpc.public_subnet_ids
}

output "availability_zones" {
  description = "Availability zones used by the VPC subnets"
  value       = module.hosted_cluster_vpc.availability_zones
}

output "nat_gateway_ids" {
  description = "IDs of NAT Gateways"
  value       = module.hosted_cluster_vpc.nat_gateway_ids
}

output "vpc_cidr" {
  description = "The CIDR block of the VPC"
  value       = module.hosted_cluster_vpc.vpc_cidr
}

output "worker_security_group_id" {
  description = "ID of the security group for worker nodes"
  value       = module.hosted_cluster_vpc.worker_security_group_id
}
