# =============================================================================
# HyperShift OIDC Module
#
# Creates the OIDC infrastructure for a Management Cluster:
# - Pod Identity for the HyperShift operator to write to S3
# - Pod Identity for the HyperShift installer Job to read config
# - Pod Identity for External Secrets Operator
# - Secrets Manager secret with OIDC configuration
#
# The S3 bucket and CloudFront distribution are provisioned separately
# in the regional account during the IoT minting pipeline step.
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      Component         = "hypershift-oidc"
      ManagementCluster = var.cluster_id
      ManagedBy         = "terraform"
    }
  )
}
