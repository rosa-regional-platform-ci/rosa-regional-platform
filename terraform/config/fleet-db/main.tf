provider "aws" {
  region = var.region
  # FedRAMP SC-13 / IA-07: Use FIPS 140-2 validated endpoints when available.
  use_fips_endpoint = can(regex("^(us|us-gov)-", var.region)) ? true : false

  dynamic "assume_role" {
    for_each = var.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-fleet-db-${var.fleet_db_id}"
    }
  }

  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
      environment   = var.environment
    }
  }
}

# =============================================================================
# VPC Module
# =============================================================================

module "vpc" {
  source = "../../modules/vpc"

  resource_name_base = var.fleet_db_id
}

# =============================================================================
# EKS Cluster
#
# Fleet-DB is a workerless EKS cluster — kube-apiserver acts as the database
# for hyperfleet CRDs. The system node pool still runs for coredns (required).
# =============================================================================

module "fleet_db_cluster" {
  source = "../../modules/eks-cluster"

  cluster_type                    = "fleet-db"
  cluster_id                      = var.fleet_db_id
  vpc_id                          = module.vpc.vpc_id
  vpc_cidr                        = module.vpc.vpc_cidr
  private_subnet_ids              = module.vpc.private_subnet_ids
  cluster_security_group_id       = module.vpc.cluster_security_group_id
  vpc_endpoints_security_group_id = module.vpc.vpc_endpoints_security_group_id
}

# =============================================================================
# ECS Bootstrap
# =============================================================================

module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.vpc.vpc_id
  private_subnets               = module.vpc.private_subnet_ids
  eks_cluster_arn               = module.fleet_db_cluster.cluster_arn
  eks_cluster_name              = module.fleet_db_cluster.cluster_name
  eks_cluster_security_group_id = module.vpc.cluster_security_group_id
  cluster_id                    = var.fleet_db_id
  container_image               = var.container_image

  repository_url    = var.repository_url
  repository_branch = var.repository_branch
}

# =============================================================================
# Bastion Module (Optional)
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  cluster_id                = var.fleet_db_id
  cluster_name              = module.fleet_db_cluster.cluster_name
  cluster_endpoint          = module.fleet_db_cluster.cluster_endpoint
  cluster_security_group_id = module.vpc.cluster_security_group_id
  vpc_id                    = module.vpc.vpc_id
  private_subnet_ids        = module.vpc.private_subnet_ids
  container_image           = var.container_image
}
