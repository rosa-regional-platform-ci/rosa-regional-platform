# =============================================================================
# Hosted Cluster VPC Configuration
#
# Creates VPC networking in a customer AWS account for HyperShift hosted
# cluster worker nodes.
#
# Run this with credentials for the CUSTOMER AWS account:
#   cd terraform/config/hosted-cluster-vpc
#   terraform init && terraform apply
# =============================================================================

provider "aws" {
  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
    }
  }
}

module "hosted_cluster_vpc" {
  source = "../../modules/hosted-cluster-vpc"

  cluster_name = var.cluster_name
}
