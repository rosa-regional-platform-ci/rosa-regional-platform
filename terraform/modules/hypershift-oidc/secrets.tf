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
# The pull secret can be provided in two ways:
# 1. Via the 'openshift_pull_secret_filename' variable pointing to a file (recommended)
# 2. Manually populated after creation using AWS CLI or console
#
# If a filename is provided, Terraform reads the file and populates the secret.
# If not, an empty placeholder is created.
# =============================================================================

resource "aws_secretsmanager_secret" "openshift_pull_secret" {
  name        = "openshift-pull-secret"
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

  # Read pull secret from file if provided, otherwise create empty placeholder
  secret_string = var.openshift_pull_secret_filename != "" ? file(var.openshift_pull_secret_filename) : jsonencode({
    ".dockerconfigjson" = ""
  })

  lifecycle {
    # Ignore changes to prevent overwriting manual updates or subsequent variable changes
    ignore_changes = [secret_string]
  }
}
