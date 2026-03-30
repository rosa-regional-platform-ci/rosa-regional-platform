# =============================================================================
# Maestro Agent IAM Role and Policies
# =============================================================================

# IAM role for Maestro Agent with Pod Identity
resource "aws_iam_role" "maestro_agent" {
  name        = "${var.management_id}-maestro-agent"
  description = "IAM role for Maestro Agent with access to local Secrets Manager"

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
      Name = "${var.management_id}-maestro-agent-role"
    }
  )
}

# Policy: Read local Secrets Manager (certificate and configuration)
resource "aws_iam_role_policy" "maestro_agent_secrets" {
  name = "${var.management_id}-maestro-agent-secrets"
  role = aws_iam_role.maestro_agent.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ]
      Resource = [
        aws_secretsmanager_secret.maestro_agent_cert.arn,
        aws_secretsmanager_secret.maestro_agent_config.arn
      ]
    }]
  })
}

# Pod Identity Association
resource "aws_eks_pod_identity_association" "maestro_agent" {
  cluster_name    = var.eks_cluster_name
  namespace       = "maestro-agent"
  service_account = "maestro-agent"
  role_arn        = aws_iam_role.maestro_agent.arn

  tags = merge(
    local.common_tags,
    {
      Name = "${var.management_id}-maestro-agent-pod-identity"
    }
  )
}
