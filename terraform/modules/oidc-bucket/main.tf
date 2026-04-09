# =============================================================================
# OIDC Bucket Module
#
# Creates the S3 bucket and CloudFront distribution for HyperShift OIDC
# discovery documents for a single management cluster. Provisioned in the
# regional account during the IoT minting step, before the management cluster
# infrastructure is deployed.
#
# The HyperShift operator (running in the management cluster) writes OIDC
# documents cross-account via the bucket policy grant below.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_name = "hypershift-${var.management_cluster_id}-oidc-${data.aws_caller_identity.current.account_id}"

  # Predictable ARN for the HyperShift operator role created later in the MC
  # Terraform apply. S3 bucket policies allow referencing principals that do
  # not yet exist --- AWS validates the account, not the role, at policy eval time.
  hypershift_operator_role_arn = "arn:aws:iam::${var.mc_account_id}:role/${var.management_cluster_id}-hypershift-operator"

  common_tags = merge(
    var.tags,
    {
      Component         = "hypershift-oidc"
      ManagementCluster = var.management_cluster_id
      ManagedBy         = "terraform"
    }
  )
}
