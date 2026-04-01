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
# The pull secret can be sourced from SSM Parameter Store (production) or
# left as a placeholder (CI/ephemeral environments where HyperShift clusters
# are not actually deployed). Set openshift_pull_secret_ssm_path to the SSM
# parameter path to enable the SSM lookup.
# =============================================================================

# Read pull secret from SSM Parameter Store (optional)
data "aws_ssm_parameter" "pull_secret" {
  count = var.openshift_pull_secret_ssm_path != "" ? 1 : 0
  name  = var.openshift_pull_secret_ssm_path
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

  # Use SSM-sourced pull secret if configured, otherwise write a placeholder.
  secret_string = var.openshift_pull_secret_ssm_path != "" ? data.aws_ssm_parameter.pull_secret[0].value : jsonencode({
    ".dockerconfigjson" = ""
  })

  lifecycle {
    # Ignore subsequent changes to allow manual updates or out-of-band population.
    ignore_changes = [secret_string]
  }
}
