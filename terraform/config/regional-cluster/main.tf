provider "aws" {
  region = var.region

  # Conditionally assume role for cross-account deployment (local dev only)
  # When target_account_id is set, assume OrganizationAccountAccessRole in target account
  # In pipelines, target_account_id is empty - ambient creds are already the target account
  dynamic "assume_role" {
    for_each = var.target_account_id != "" ? [1] : []
    content {
      role_arn     = "arn:aws:iam::${var.target_account_id}:role/OrganizationAccountAccessRole"
      session_name = "terraform-regional-${var.target_alias}"
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

# Call the EKS cluster module for regional cluster infrastructure
module "regional_cluster" {
  source = "../../modules/eks-cluster"

  # Required variables
  cluster_type = "regional-cluster"
  cluster_id   = var.regional_id
}

# Call the ECS bootstrap module for external bootstrap execution
module "ecs_bootstrap" {
  source = "../../modules/ecs-bootstrap"

  vpc_id                        = module.regional_cluster.vpc_id
  private_subnets               = module.regional_cluster.private_subnets
  eks_cluster_arn               = module.regional_cluster.cluster_arn
  eks_cluster_name              = module.regional_cluster.cluster_name
  eks_cluster_security_group_id = module.regional_cluster.cluster_security_group_id
  cluster_id                    = var.regional_id
  container_image               = var.container_image

  # ArgoCD bootstrap configuration
  repository_url    = var.repository_url
  repository_branch = var.repository_branch
}

# =============================================================================
# Bastion Module (Optional)
# =============================================================================

module "bastion" {
  count  = var.enable_bastion ? 1 : 0
  source = "../../modules/bastion"

  cluster_id                = var.regional_id
  cluster_name              = module.regional_cluster.cluster_name
  cluster_endpoint          = module.regional_cluster.cluster_endpoint
  cluster_security_group_id = module.regional_cluster.cluster_security_group_id
  vpc_id                    = module.regional_cluster.vpc_id
  private_subnet_ids        = module.regional_cluster.private_subnets
  container_image           = var.container_image
}

# =============================================================================
# API Gateway Module
# =============================================================================

module "api_gateway" {
  source = "../../modules/api-gateway"

  vpc_id                 = module.regional_cluster.vpc_id
  private_subnet_ids     = module.regional_cluster.private_subnets
  regional_id            = var.regional_id
  node_security_group_id = module.regional_cluster.node_security_group_id
  cluster_name           = module.regional_cluster.cluster_name
}

# Maestro Infrastructure Module
# =============================================================================

# Call the Maestro infrastructure module for MQTT-based orchestration
module "maestro_infrastructure" {
  source = "../../modules/maestro-infrastructure"

  # Required variables from EKS cluster
  regional_id                           = var.regional_id
  vpc_id                                = module.regional_cluster.vpc_id
  private_subnets                       = module.regional_cluster.private_subnets
  eks_cluster_name                      = module.regional_cluster.cluster_name
  eks_cluster_security_group_id         = module.regional_cluster.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  # Bastion access (if enabled)
  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : null

  # Database configuration (adjust for production)
  db_instance_class      = var.maestro_db_instance_class
  db_multi_az            = var.maestro_db_multi_az
  db_deletion_protection = var.maestro_db_deletion_protection

  # MQTT topic prefix
  mqtt_topic_prefix = var.maestro_mqtt_topic_prefix
}

# =============================================================================
# Authorization Module
# =============================================================================

# Call the Authz module for Cedar/AVP-based authorization
module "authz" {
  source = "../../modules/authz"

  regional_id      = var.regional_id
  eks_cluster_name = module.regional_cluster.cluster_name

  # DynamoDB configuration
  billing_mode                  = var.authz_billing_mode
  enable_point_in_time_recovery = var.authz_enable_pitr
  enable_deletion_protection    = var.authz_deletion_protection

  # Pod Identity configuration
  frontend_api_namespace       = var.authz_frontend_api_namespace
  frontend_api_service_account = var.authz_frontend_api_service_account

  # Bootstrap privileged accounts (current account + any additional allowed accounts)
  # Use distinct() to remove any duplicate account IDs
  bootstrap_accounts = distinct(compact(split(",", var.api_additional_allowed_accounts != "" ? "${data.aws_caller_identity.current.account_id},${var.api_additional_allowed_accounts}" : data.aws_caller_identity.current.account_id)))
}

# =============================================================================
# HyperFleet Infrastructure Module
# =============================================================================

# Call the HyperFleet infrastructure module for cluster lifecycle management
module "hyperfleet_infrastructure" {
  source = "../../modules/hyperfleet-infrastructure"

  # Required variables from EKS cluster
  regional_id                           = var.regional_id
  vpc_id                                = module.regional_cluster.vpc_id
  private_subnets                       = module.regional_cluster.private_subnets
  eks_cluster_name                      = module.regional_cluster.cluster_name
  eks_cluster_security_group_id         = module.regional_cluster.cluster_security_group_id
  eks_cluster_primary_security_group_id = module.regional_cluster.node_security_group_id

  # Bastion access (if enabled)
  bastion_security_group_id = var.enable_bastion ? module.bastion[0].security_group_id : null

  # Database configuration
  db_instance_class      = var.hyperfleet_db_instance_class
  db_multi_az            = var.hyperfleet_db_multi_az
  db_deletion_protection = var.hyperfleet_db_deletion_protection

  # Message queue configuration
  mq_instance_type   = var.hyperfleet_mq_instance_type
  mq_deployment_mode = var.hyperfleet_mq_deployment_mode
}
