# =============================================================================
# Hosted Cluster VPC Module
#
# Creates VPC networking in a customer AWS account for HyperShift hosted
# cluster worker nodes. Provides public and private subnets across multiple
# availability zones with NAT gateway egress for private subnets.
#
# This module is simpler than the eks-cluster VPC — it provides only the
# core networking (VPC, subnets, NAT, routing) without VPC endpoints or
# security groups, which are managed separately by HyperShift.
# =============================================================================

data "aws_region" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  # Use provided AZs if given, otherwise auto-detect, sliced to match subnet count
  azs = length(var.availability_zones) > 0 ? slice(var.availability_zones, 0, length(var.private_subnet_cidrs)) : slice(data.aws_availability_zones.available.names, 0, length(var.private_subnet_cidrs))

  # Name prefix for all resources
  name_prefix = "${var.cluster_name}-hc"

  # Common tags applied to all resources
  common_tags = merge(
    var.tags,
    {
      Module          = "hosted-cluster-vpc"
      Cluster         = var.cluster_name
      ManagedBy       = "terraform"
      red-hat-managed = "true"
    }
  )
}
