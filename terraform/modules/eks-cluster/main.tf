# =============================================================================
# EKS Cluster Configuration
#
# Creates a fully private EKS cluster with Auto Mode enabled.
# Includes KMS encryption for secrets, proper networking,
# and managed addons for a complete cluster deployment.
# VPC and networking are provided as inputs from the vpc module.
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
# -----------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  name     = local.cluster_id
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.cluster_version

  bootstrap_self_managed_addons = false

  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks_secrets.arn
    }
  }

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false
    security_group_ids      = [var.cluster_security_group_id]
  }

  compute_config {
    enabled       = !var.enable_karpenter
    node_pools    = var.enable_karpenter ? null : ["system"]
    node_role_arn = var.enable_karpenter ? null : aws_iam_role.eks_auto_mode_node.arn
  }

  kubernetes_network_config {
    elastic_load_balancing {
      enabled = !var.enable_karpenter
    }
  }

  storage_config {
    block_storage {
      enabled = !var.enable_karpenter
    }
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_managed,
    aws_cloudwatch_log_group.eks_cluster,
    aws_kms_key.eks_secrets
  ]
}

# -----------------------------------------------------------------------------
# Bootstrap node group — runs only the Karpenter controller.
# Uses AL2023 (not RHEL) intentionally: this group exists only to provide
# capacity for the Karpenter controller pod before Karpenter can provision
# RHEL workload nodes.
# -----------------------------------------------------------------------------
resource "aws_eks_node_group" "karpenter_bootstrap" {
  count = var.enable_karpenter ? 1 : 0

  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.cluster_id}-karpenter-bootstrap"
  node_role_arn   = aws_iam_role.eks_auto_mode_node.arn
  subnet_ids      = var.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = ["t3.small"]

  scaling_config {
    desired_size = 2
    min_size     = 2
    max_size     = 3
  }

  labels = {
    "karpenter.sh/controller" = "true"
  }

  taint {
    key    = "karpenter.sh/controller"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  depends_on = [aws_eks_cluster.main]
}

# -----------------------------------------------------------------------------
# Karpenter — installed via Helm after the bootstrap node group is ready.
# ECR Public is always in us-east-1; the default provider is used directly
# since this cluster is in us-east-1.
# -----------------------------------------------------------------------------
data "aws_ecrpublic_authorization_token" "karpenter" {
  count = var.enable_karpenter ? 1 : 0
}

resource "helm_release" "karpenter" {
  count = var.enable_karpenter ? 1 : 0

  namespace        = "kube-system"
  name             = "karpenter"
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = "1.4.0"
  create_namespace = false

  repository_username = data.aws_ecrpublic_authorization_token.karpenter[0].user_name
  repository_password = data.aws_ecrpublic_authorization_token.karpenter[0].password

  set {
    name  = "settings.clusterName"
    value = aws_eks_cluster.main.name
  }

  set {
    name  = "settings.interruptionQueue"
    value = aws_sqs_queue.karpenter_interruption[0].name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter_controller[0].arn
  }

  set {
    name  = "tolerations[0].key"
    value = "karpenter.sh/controller"
  }
  set {
    name  = "tolerations[0].operator"
    value = "Exists"
  }
  set {
    name  = "tolerations[0].effect"
    value = "NoSchedule"
  }

  depends_on = [aws_eks_node_group.karpenter_bootstrap]
}

# -----------------------------------------------------------------------------
# EKS Managed Addons
#
# Essential addons for cluster functionality:
# - CoreDNS: cluster DNS resolution
# - metrics-server: pod/node metrics for HPA and kubectl top
# - Pod Identity Agent: AWS IAM integration for workloads (DaemonSet, safe pre-node)
# - AWS Secrets Store CSI Driver Provider: Secret mounting (DaemonSet, safe pre-node)
#
# CoreDNS and metrics-server are declared here so Terraform creates them before
# the ECS bootstrap task runs. The built-in "system" pool provides nodes for them
# to schedule on, so there is no deadlock. Without this declaration, a fresh cluster
# has no coredns/metrics-server addons and the bootstrap wait-addon-active call fails
# with ResourceNotFoundException.
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
}

resource "aws_eks_addon" "metrics_server" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "metrics-server"
}

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
