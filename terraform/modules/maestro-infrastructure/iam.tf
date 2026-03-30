# =============================================================================
# IAM Roles for Maestro Components
#
# Creates IAM roles for use with EKS Pod Identity:
# - Maestro Server: Access to RDS, Secrets Manager
# - External Secrets Operator: Access to Secrets Manager (read-only)
#
# Note: IoT Core MQTT authorization uses X.509 certificate policies (iot.tf),
# not IAM role policies. IAM iot:* actions only apply to SigV4/HTTP connections
# which Maestro does not use.
# =============================================================================

# =============================================================================
# Maestro Server IAM Role
# =============================================================================

resource "aws_iam_role" "maestro_server" {
  name        = "${var.regional_id}-maestro-server"
  description = "IAM role for Maestro Server with access to RDS and Secrets Manager"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-maestro-server-role"
      Component = "maestro-server"
    }
  )
}

# Maestro Server Policy - Secrets Manager read access
resource "aws_iam_role_policy" "maestro_server_secrets" {
  name = "${var.regional_id}-maestro-server-secrets-policy"
  role = aws_iam_role.maestro_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = [
          aws_secretsmanager_secret.maestro_server_cert.arn,
          aws_secretsmanager_secret.maestro_server_config.arn,
          aws_secretsmanager_secret.maestro_db_credentials.arn
        ]
      }
    ]
  })
}

# Pod Identity Association for Maestro Server
resource "aws_eks_pod_identity_association" "maestro_server" {
  cluster_name    = var.eks_cluster_name
  namespace       = "maestro-server"
  service_account = "maestro-server"
  role_arn        = aws_iam_role.maestro_server.arn

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-maestro-server-pod-identity"
      Component = "maestro-server"
    }
  )
}

