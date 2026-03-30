# =============================================================================
# IAM Roles for Maestro Components
#
# Creates IAM roles for use with EKS Pod Identity:
# - Maestro Server: Access to RDS, IoT Core (publish), Secrets Manager
# - Maestro Agent: Access to IoT Core (subscribe), Secrets Manager
# - External Secrets Operator: Access to Secrets Manager (read-only)
# =============================================================================

# =============================================================================
# Maestro Server IAM Role
# =============================================================================

resource "aws_iam_role" "maestro_server" {
  name        = "${var.regional_id}-maestro-server"
  description = "IAM role for Maestro Server with access to RDS, IoT, and Secrets Manager"

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

# Maestro Server Policy - IoT Core permissions
#
# NOTE: These IAM actions only apply to SigV4/HTTP IoT connections (port 443).
# Maestro uses X.509 certificate-based MQTT (port 8883), for which AWS IoT Core
# evaluates only the IoT certificate policy (aws_iot_policy in iot.tf) — IAM
# policies are not consulted. This policy is scoped accurately for defence-in-depth
# should the authentication method ever change.
#
# Server role: publishes sourceevents TO agents, publishes agentevents for
# spec-resync responses, and subscribes/receives agentevents FROM agents.
resource "aws_iam_role_policy" "maestro_server_iot" {
  name = "${var.regional_id}-maestro-server-iot-policy"
  role = aws_iam_role.maestro_server.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Connect"
        Effect = "Allow"
        Action = ["iot:Connect"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:client/maestro-*"
        ]
      },
      {
        Sid    = "Publish"
        Effect = "Allow"
        Action = ["iot:Publish"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/sourceevents",
          # Server also publishes to agentevents for spec-resync responses
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/agentevents"
        ]
      },
      {
        Sid    = "Subscribe"
        Effect = "Allow"
        Action = ["iot:Subscribe"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topicfilter/sources/${var.regional_id}/consumers/*/agentevents"
        ]
      },
      {
        Sid    = "Receive"
        Effect = "Allow"
        Action = ["iot:Receive"]
        Resource = [
          "arn:aws:iot:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:topic/sources/${var.regional_id}/consumers/*/agentevents"
        ]
      }
    ]
  })
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

