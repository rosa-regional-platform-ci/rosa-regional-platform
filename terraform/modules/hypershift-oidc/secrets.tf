# =============================================================================
# Secrets Manager - HyperShift Configuration
#
# Stores OIDC configuration that the install Job reads via ASCP CSI driver.
# This eliminates hardcoded values in ArgoCD config — the bucket name and
# region are derived from Terraform and consumed at runtime.
# =============================================================================

resource "aws_secretsmanager_secret" "hypershift_config" {
  name        = "hypershift/${var.cluster_id}-config"
  description = "HyperShift OIDC configuration for the install Job"

  tags = merge(
    local.common_tags,
    {
      Name = "hypershift-config"
    }
  )
}

resource "aws_secretsmanager_secret_version" "hypershift_config" {
  secret_id = aws_secretsmanager_secret.hypershift_config.id

  secret_string = jsonencode({
    oidcBucketName   = aws_s3_bucket.oidc.id
    oidcBucketRegion = data.aws_region.current.id
  })
}

# =============================================================================
# Secrets Manager - OpenShift Pull Secret
#
# Stores the OpenShift pull secret that is required to deploy HyperShift
# clusters. This secret is created at provision time and will be synced to
# individual cluster namespaces via SecretProviderClass when clusters are
# provisioned.
#
# The pull secret is read from SSM Parameter Store at /infra/pull-secret
# and synchronized to AWS Secrets Manager for consumption by HyperShift.
# =============================================================================

# Read pull secret from SSM Parameter Store (SecureString, KMS-encrypted)
data "aws_ssm_parameter" "pull_secret" {
  name            = "/infra/pull-secret"
  with_decryption = true
}

resource "aws_secretsmanager_secret" "openshift_pull_secret" {
  name        = "${var.cluster_id}-openshift-pull-secret"
  description = "OpenShift pull secret for HyperShift cluster deployments"

  tags = merge(
    local.common_tags,
    {
      Name = "openshift-pull-secret"
    }
  )
}

resource "aws_secretsmanager_secret_version" "openshift_pull_secret" {
  secret_id = aws_secretsmanager_secret.openshift_pull_secret.id

  # Read pull secret from SSM Parameter Store
  secret_string = data.aws_ssm_parameter.pull_secret.value
}
