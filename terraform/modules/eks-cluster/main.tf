# =============================================================================
# EKS Cluster Configuration
#
# Creates a fully private EKS cluster with Auto Mode enabled.
# Includes KMS encryption for secrets, proper networking,
# and managed addons for a complete cluster deployment.
# =============================================================================

# -----------------------------------------------------------------------------
# FedRAMP AU-09: KMS Key for Audit Log Encryption
#
# Customer-managed KMS key encrypts EKS CloudWatch log data at rest so that
# audit records cannot be read without KMS key authorization. Note: KMS does
# not prevent deletion — log group deletion and retention are controlled by
# IAM permissions (logs:DeleteLogGroup) and the retention_in_days setting.
# -----------------------------------------------------------------------------

resource "aws_kms_key" "cloudwatch_logs" {
  description             = "KMS key for EKS cluster CloudWatch log group encryption (FedRAMP AU-09)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${data.aws_region.current.id}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:log-group:/aws/eks/${local.cluster_id}/cluster"
          }
        }
      }
    ]
  })

  tags = {
    Name = "${local.cluster_id}-cloudwatch-logs"
  }
}

resource "aws_kms_alias" "cloudwatch_logs" {
  name          = "alias/${local.cluster_id}-cloudwatch-logs"
  target_key_id = aws_kms_key.cloudwatch_logs.key_id
}

# -----------------------------------------------------------------------------
# CloudWatch Logging
# -----------------------------------------------------------------------------

# Note: setting kms_key_id on an existing log group only encrypts newly ingested
# events. Historical events remain under the previously configured key (or no key).
# For brownfield clusters, export historical logs to S3 before applying this change,
# or document a compliance exception. Do NOT delete/recreate the log group as this
# would discard retained audit logs required by AU-11.
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.cluster_id}/cluster"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.cloudwatch_logs.arn

  depends_on = [aws_kms_key.cloudwatch_logs]
}

# -----------------------------------------------------------------------------
# EKS Cluster
#
# Fully private EKS cluster with Auto Mode for simplified node management.
# Auto Mode requires specific configurations for authentication and bootstrapping.
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = local.cluster_id
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  # Required for EKS Auto Mode - disable self-managed addon bootstrapping
  bootstrap_self_managed_addons = false

  # Required for EKS Auto Mode - specify authentication mode
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  # Encryption at rest for Kubernetes secrets using customer-managed KMS key
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
  }

  vpc_config {
    subnet_ids              = aws_subnet.private[*].id
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }

  compute_config {
    enabled = true
    # No built-in node pools — all scheduling is handled by the custom FIPS NodePool/NodeClass.
    # EKS rejects node_role_arn without node_pools, so both must be null.
    node_pools    = []
    node_role_arn = null

    # TODO: Enable IMDSv2 enforcement for security compliance
    # node_pool_defaults configuration for launch template metadata_options
    # is not yet supported in AWS provider 6.x for EKS Auto Mode.
    # Will be implemented when provider support becomes available.
    # See https://github.com/hashicorp/terraform-provider-aws/issues/40486
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = true
    }
  }

  storage_config {
    block_storage {
      enabled = true
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  # Explicit dependencies ensure IAM is ready before cluster creation starts
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_managed,
    aws_cloudwatch_log_group.eks_cluster,
    aws_kms_key.eks_secrets
  ]
}

# -----------------------------------------------------------------------------
# Node Role Access Entry
#
# With node_pools=[] and node_role_arn=null (required together — EKS rejects
# node_role_arn without node_pools), EKS does not automatically authorize the
# node IAM role to join the cluster. Custom Karpenter NodePools reference this
# role via the NodeClass, so we must register it explicitly as EC2_LINUX.
# Without this, NodeClass.Status shows UnauthorizedNodeRole and Karpenter
# cannot provision any nodes.
# -----------------------------------------------------------------------------

resource "aws_eks_access_entry" "node_role" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.eks_auto_mode_node.arn
  type          = "EC2_LINUX"

  depends_on = [aws_eks_cluster.main]
}

# -----------------------------------------------------------------------------
# EKS Managed Addons
#
# Essential addons for cluster functionality:
# - Pod Identity Agent: AWS IAM integration for workloads (DaemonSet, safe pre-node)
# - AWS Secrets Store CSI Driver Provider: Secret mounting (DaemonSet, safe pre-node)
#
# CoreDNS and metrics-server are Deployment-based addons that require running
# pods, which means they need nodes. With node_pools=[] (FIPS-only mode), no
# AWS-managed nodes exist at Terraform apply time — nodes are provisioned by
# Karpenter after the ECS bootstrap applies the FIPS NodePool. Creating these
# addons in Terraform would deadlock (addon DEGRADED → 20m timeout → Stage 2
# never runs → no FIPS NodePool → no nodes → addon never ACTIVE). They are
# instead created by the ECS bootstrap task after nodes are ready.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
}

# AWS Secrets Store CSI Driver Provider (e.g. for Maestro agent secret mounting)
resource "aws_eks_addon" "aws_secrets_store_csi_driver_provider" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "aws-secrets-store-csi-driver-provider"

  configuration_values = jsonencode({
    secrets-store-csi-driver = {
      syncSecret = {
        enabled = true
      }
    }
  })
}
