# =============================================================================
# Hosted Cluster IAM Configuration
#
# Creates IAM OIDC provider and STS roles in a customer AWS account for
# HyperShift hosted control plane components to assume.
#
# Run this with credentials for the CUSTOMER AWS account.
# The oidc_issuer_url should be the CloudFront domain from the MC's
# terraform output (oidc_cloudfront_domain).
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

module "hosted_cluster_iam" {
  source = "../../modules/hosted-cluster-iam"

  cluster_name  = var.cluster_name
  oidc_base_url = var.oidc_base_url
}
