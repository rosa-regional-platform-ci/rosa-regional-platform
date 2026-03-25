# =============================================================================
# EKS Cluster Configuration
#
# Creates a fully private EKS cluster with Auto Mode enabled. 
# Includes KMS encryption for secrets, proper networking,
# and managed addons for a complete cluster deployment.
# =============================================================================

# -----------------------------------------------------------------------------
# CloudWatch Logging
# -----------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/${local.cluster_id}/cluster"
  retention_in_days = 30
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
    enabled       = true
    node_pools    = ["general-purpose"]
    node_role_arn = aws_iam_role.eks_auto_mode_node.arn

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
# EKS Managed Addons
#
# Essential addons for cluster functionality:
# - CoreDNS: DNS resolution for pods and services
# - Pod Identity Agent: AWS IAM integration for workloads
# - AWS Secrets Store CSI Driver Provider: Secret mounting
# -----------------------------------------------------------------------------

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "coredns"
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

# AWS EBS CSI Driver for persistent volume provisioning
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name             = aws_eks_cluster.main.name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver.arn
}

# IAM Role for EBS CSI Driver (Pod Identity)
resource "aws_iam_role" "ebs_csi_driver" {
  name = "${local.cluster_id}-ebs-csi"

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

  tags = {
    Name = "${local.cluster_id}-ebs-csi"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi_driver" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi_driver.arn

  # Wait for addon to create the service account
  depends_on = [aws_eks_addon.ebs_csi_driver]

  tags = {
    Name = "${local.cluster_id}-ebs-csi"
  }
}