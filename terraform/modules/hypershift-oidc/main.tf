# =============================================================================
# HyperShift OIDC Module
#
# Creates the OIDC infrastructure for a Management Cluster:
# - Private S3 bucket for OIDC discovery documents
# - CloudFront distribution for public OIDC endpoint
# - Pod Identity for the HyperShift operator to write to S3
#
# The CloudFront domain becomes the OIDC issuer base URL given to customers.
# Each hosted cluster gets a path prefix under this domain.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  oidc_bucket_name = "hypershift-${data.aws_caller_identity.current.account_id}-${var.cluster_id}-oidc"

  common_tags = merge(
    var.tags,
    {
      Component         = "hypershift-oidc"
      ManagementCluster = var.cluster_id
      ManagedBy         = "terraform"
    }
  )
}
