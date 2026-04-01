# =============================================================================
# Grafana Secrets – AWS Secrets Manager entries
#
# Generates random credentials and stores them in Secrets Manager.
# The ECS bootstrap task reads these values and creates the Kubernetes Secrets
# that Grafana reads (see terraform/modules/ecs-bootstrap/main.tf).
# =============================================================================

data "aws_caller_identity" "current" {}


locals {
  common_tags = merge(
    var.tags,
    {
      Component = "grafana"
      ClusterId = var.cluster_id
      ManagedBy = "terraform"
    }
  )
}

# -----------------------------------------------------------------------------
# Random credential generation
# -----------------------------------------------------------------------------

resource "random_password" "grafana_admin" {
  length           = 32
  special          = true
  override_special = "!#$%&*-_=+?"
}

resource "random_password" "grafana_secret_key" {
  length  = 32
  special = false
}

# -----------------------------------------------------------------------------
# Secrets Manager: admin credentials
# Path: /<cluster_id>/grafana/admin-credentials
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "grafana_admin" {
  name                    = "/${var.cluster_id}/grafana/admin-credentials"
  description             = "Grafana admin username and password for ${var.cluster_id}"
  recovery_window_in_days = 7

  tags = merge(local.common_tags, { Name = "${var.cluster_id}-grafana-admin-credentials" })
}

resource "aws_secretsmanager_secret_version" "grafana_admin" {
  secret_id = aws_secretsmanager_secret.grafana_admin.id
  secret_string = jsonencode({
    username = var.grafana_admin_username
    password = random_password.grafana_admin.result
  })
}

# -----------------------------------------------------------------------------
# Secrets Manager: AES-256 database secret key
# Path: /<cluster_id>/grafana/secrets
# -----------------------------------------------------------------------------

resource "aws_secretsmanager_secret" "grafana_secrets" {
  name                    = "/${var.cluster_id}/grafana/secrets"
  description             = "Grafana database encryption secret key for ${var.cluster_id}"
  recovery_window_in_days = 7

  tags = merge(local.common_tags, { Name = "${var.cluster_id}-grafana-secrets" })
}

resource "aws_secretsmanager_secret_version" "grafana_secrets" {
  secret_id = aws_secretsmanager_secret.grafana_secrets.id
  secret_string = jsonencode({
    secret_key = random_password.grafana_secret_key.result
  })
}
