# =============================================================================
# IAM Roles for HyperFleet Components
#
# Creates IAM roles for use with EKS Pod Identity:
# - HyperFleet API: Access to database credentials
# - HyperFleet Sentinel: Access to message queue credentials
# - HyperFleet Adapter: Access to message queue credentials
# =============================================================================

# =============================================================================
# HyperFleet API IAM Role
# =============================================================================

resource "aws_iam_role" "hyperfleet_api" {
  name        = "${var.regional_id}-hyperfleet-api"
  description = "IAM role for HyperFleet API with access to database credentials"

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
      Name      = "${var.regional_id}-hyperfleet-api-role"
      Component = "hyperfleet-api"
    }
  )
}

# HyperFleet API Policy - Secrets Manager read access for database credentials
resource "aws_iam_role_policy" "hyperfleet_api_secrets" {
  name = "${var.regional_id}-hyperfleet-api-secrets-policy"
  role = aws_iam_role.hyperfleet_api.id

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
          aws_secretsmanager_secret.hyperfleet_db_credentials.arn
        ]
      }
    ]
  })
}

# Pod Identity Association for HyperFleet API
resource "aws_eks_pod_identity_association" "hyperfleet_api" {
  cluster_name    = var.eks_cluster_name
  namespace       = "hyperfleet-system"
  service_account = "hyperfleet-api-sa"
  role_arn        = aws_iam_role.hyperfleet_api.arn

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-api-pod-identity"
      Component = "hyperfleet-api"
    }
  )
}

# =============================================================================
# HyperFleet Sentinel IAM Role
# =============================================================================

resource "aws_iam_role" "hyperfleet_sentinel" {
  name        = "${var.regional_id}-hyperfleet-sentinel"
  description = "IAM role for HyperFleet Sentinel with access to message queue credentials"

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
      Name      = "${var.regional_id}-hyperfleet-sentinel-role"
      Component = "hyperfleet-sentinel"
    }
  )
}

# HyperFleet Sentinel Policy - Secrets Manager read access for MQ credentials
resource "aws_iam_role_policy" "hyperfleet_sentinel_secrets" {
  name = "${var.regional_id}-hyperfleet-sentinel-secrets-policy"
  role = aws_iam_role.hyperfleet_sentinel.id

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
          aws_secretsmanager_secret.hyperfleet_mq_credentials.arn
        ]
      }
    ]
  })
}

# Pod Identity Association for HyperFleet Sentinel
resource "aws_eks_pod_identity_association" "hyperfleet_sentinel" {
  cluster_name    = var.eks_cluster_name
  namespace       = "hyperfleet-system"
  service_account = "sentinel-sa"
  role_arn        = aws_iam_role.hyperfleet_sentinel.arn

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-sentinel-pod-identity"
      Component = "hyperfleet-sentinel"
    }
  )
}

# =============================================================================
# HyperFleet Adapter IAM Role
# =============================================================================

resource "aws_iam_role" "hyperfleet_adapter" {
  name        = "${var.regional_id}-hyperfleet-adapter"
  description = "IAM role for HyperFleet Adapter with access to message queue credentials"

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
      Name      = "${var.regional_id}-hyperfleet-adapter-role"
      Component = "hyperfleet-adapter"
    }
  )
}

# HyperFleet Adapter Policy - Secrets Manager read access for MQ credentials
resource "aws_iam_role_policy" "hyperfleet_adapter_secrets" {
  name = "${var.regional_id}-hyperfleet-adapter-secrets-policy"
  role = aws_iam_role.hyperfleet_adapter.id

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
          aws_secretsmanager_secret.hyperfleet_mq_credentials.arn
        ]
      }
    ]
  })
}

# Pod Identity Association for HyperFleet Adapter
resource "aws_eks_pod_identity_association" "hyperfleet_adapter" {
  cluster_name    = var.eks_cluster_name
  namespace       = "hyperfleet-system"
  service_account = "hyperfleet-adapter-sa"
  role_arn        = aws_iam_role.hyperfleet_adapter.arn

  tags = merge(
    local.common_tags,
    {
      Name      = "${var.regional_id}-hyperfleet-adapter-pod-identity"
      Component = "hyperfleet-adapter"
    }
  )
}
