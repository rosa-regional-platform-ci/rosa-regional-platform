provider "aws" {
  region = var.region

  dynamic "assume_role" {
    for_each = var.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-regional-${var.regional_id}"
    }
  }

  default_tags {
    tags = {
      app-code      = var.app_code
      service-phase = var.service_phase
      cost-center   = var.cost_center
      environment   = var.environment
      sector        = var.sector
    }
  }
}

# =============================================================================
# Data Sources
# =============================================================================

data "aws_caller_identity" "current" {}

# =============================================================================
# VPC Module - provisions first, unblocks everything else
# =============================================================================

module "vpc" {
  source = "../../modules/vpc"

  resource_name_base = var.regional_id
}

# =============================================================================
# EKS Cluster - depends only on VPC
# =============================================================================

module "regional_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_type                    = "regional-cluster"
  cluster_id                      = var.regional_id
  vpc_id                          = module.vpc.vpc_id
  vpc_cidr                        = module.vpc.vpc_cidr
  private_subnet_ids              = module.vpc.private_subnet_ids
  cluster_security_group_id       = module.vpc.cluster_security_group_id
  vpc_endpoints_security_group_id = module.vpc.vpc_endpoints_security_group_id
}

# =============================================================================
# ECS Bootstrap - depends on VPC + EKS
# =============================================================================

module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.vpc.vpc_id
  private_subnets               = module.vpc.private_subnet_ids
  eks_cluster_arn               = module.regional_cluster.cluster_arn
  eks_cluster_name              = module.regional_cluster.cluster_name
  eks_cluster_security_group_id = module.vpc.cluster_security_group_id
  cluster_id                    = var.regional_id
  container_image               = var.container_image

  repository_url    = var.repository_url
  repository_branch = var.repository_branch
}

# =============================================================================
# Bastion Module (Optional) - depends on VPC + EKS
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  cluster_id                = var.regional_id
  cluster_name              = module.regional_cluster.cluster_name
  cluster_endpoint          = module.regional_cluster.cluster_endpoint
  cluster_security_group_id = module.vpc.cluster_security_group_id
  vpc_id                    = module.vpc.vpc_id
  private_subnet_ids        = module.vpc.private_subnet_ids
  container_image           = var.container_image
}

# =============================================================================
# API Gateway Module - depends on VPC + EKS (needs node_security_group_id)
# =============================================================================

module "api_gateway" {
  source = "../../modules/api-gateway"

  vpc_id                 = module.vpc.vpc_id
  private_subnet_ids     = module.vpc.private_subnet_ids
  regional_id            = var.regional_id
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name
}

# =============================================================================
# Maestro Infrastructure Module - VPC from vpc module, node SG from EKS
# =============================================================================

module "maestro_infrastructure" {
  source = "../../modules/maestro-infrastructure"

  # Required variables from EKS cluster
  regional_id                           = var.regional_id
  vpc_id                                = module.vpc.vpc_id
  private_subnets                       = module.vpc.private_subnet_ids
  eks_cluster_name                      = module.regional_cluster.cluster_name
  eks_cluster_security_group_id         = module.vpc.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  bastion_enabled           = var.enable_bastion
  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : null

  db_instance_class      = var.maestro_db_instance_class
  db_multi_az            = var.maestro_db_multi_az
  db_deletion_protection = var.maestro_db_deletion_protection

  mqtt_topic_prefix = var.maestro_mqtt_topic_prefix
}

# =============================================================================
# Authorization Module - only needs resource_name_base + cluster_name
# =============================================================================

module "authz" {
  source = "../../modules/authz"

  regional_id      = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  billing_mode                  = var.authz_billing_mode
  enable_point_in_time_recovery = var.authz_enable_pitr
  enable_deletion_protection    = var.authz_deletion_protection

  frontend_api_namespace       = var.authz_frontend_api_namespace
  frontend_api_service_account = var.authz_frontend_api_service_account

  bootstrap_accounts = distinct(compact(split(",", var.api_additional_allowed_accounts != "" ? "${data.aws_caller_identity.current.account_id},${var.api_additional_allowed_accounts}" : data.aws_caller_identity.current.account_id)))
}

# =============================================================================
# HyperFleet Infrastructure Module - MQ broker provisions in parallel with EKS
# =============================================================================

module "hyperfleet_infrastructure" {
  source = "../../modules/hyperfleet-infrastructure"

  # Required variables from EKS cluster
  regional_id                           = var.regional_id
  vpc_id                                = module.vpc.vpc_id
  private_subnets                       = module.vpc.private_subnet_ids
  eks_cluster_name                      = module.regional_cluster.cluster_name
  eks_cluster_security_group_id         = module.vpc.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  bastion_enabled           = var.enable_bastion
  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : null

  db_instance_class      = var.hyperfleet_db_instance_class
  db_multi_az            = var.hyperfleet_db_multi_az
  db_deletion_protection = var.hyperfleet_db_deletion_protection

  mq_instance_type   = var.hyperfleet_mq_instance_type
  mq_deployment_mode = var.hyperfleet_mq_deployment_mode
}
