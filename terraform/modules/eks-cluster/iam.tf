# =============================================================================
# IAM Roles and Policies for EKS Cluster
#
# Creates IAM roles required for EKS Auto Mode operation:
# - Cluster service role with required permissions
# - Node group role for Auto Mode managed nodes
# =============================================================================

# -----------------------------------------------------------------------------
# EKS Cluster Service Role
#
# Role assumed by EKS control plane. Auto Mode requires additional permissions
# including sts:TagSession for resource tagging.
# See: https://docs.aws.amazon.com/eks/latest/userguide/automode-get-started-cli.html#auto-mode-create-roles
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_id}-cluster-role"

  # Auto Mode REQUIRES sts:TagSession to propagate tags to managed infra
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = ["sts:AssumeRole", "sts:TagSession"]
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSComputePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSBlockStoragePolicy",
    "arn:aws:iam::aws:policy/AmazonEKSLoadBalancingPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSNetworkingPolicy"
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_cluster.name
}

# -----------------------------------------------------------------------------
# EKS Auto Mode Node Role
#
# Role assumed by Auto Mode managed nodes. Includes all required policies
# for node operation, networking, storage, and load balancing.
# See: https://docs.aws.amazon.com/eks/latest/userguide/automode-get-started-cli.html#auto-mode-create-roles
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eks_auto_mode_node" {
  name = "${local.cluster_id}-auto-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = ["sts:AssumeRole", "sts:TagSession"]
      Effect = "Allow"
      Principal = {
        Service = ["ec2.amazonaws.com", "eks.amazonaws.com"]
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "auto_node_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodeMinimalPolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly"
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_auto_mode_node.name
}

# AmazonEKSWorkerNodeMinimalPolicy is Auto Mode-specific and insufficient for
# standard managed node groups. The bootstrap node group (AL2023) needs the
# full worker node policy and CNI policy so kubelet can register and the VPC
# CNI can manage ENIs for pod networking.
resource "aws_iam_role_policy_attachment" "karpenter_bootstrap_node_policies" {
  for_each = var.enable_karpenter ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
  ]) : toset([])
  policy_arn = each.value
  role       = aws_iam_role.eks_auto_mode_node.name
}

# -----------------------------------------------------------------------------
# Karpenter Controller IRSA
# -----------------------------------------------------------------------------
data "tls_certificate" "eks_oidc" {
  count = var.enable_karpenter ? 1 : 0
  url   = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  count           = var.enable_karpenter ? 1 : 0
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc[0].certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.cluster_id}-karpenter-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "")}:sub" = "system:serviceaccount:kube-system:karpenter"
          "${replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "karpenter_controller" {
  count = var.enable_karpenter ? 1 : 0
  name  = "karpenter-controller"
  role  = aws_iam_role.karpenter_controller[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowEC2NodeProvisioning"
        Effect = "Allow"
        Action = [
          "ec2:CreateFleet", "ec2:CreateLaunchTemplate", "ec2:CreateTags",
          "ec2:DeleteLaunchTemplate", "ec2:DescribeAvailabilityZones",
          "ec2:DescribeImages", "ec2:DescribeInstances",
          "ec2:DescribeInstanceTypeOfferings", "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplates", "ec2:DescribeSecurityGroups",
          "ec2:DescribeSpotPriceHistory", "ec2:DescribeSubnets",
          "ec2:RunInstances", "ec2:TerminateInstances"
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowPassRoleToNodes"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.eks_auto_mode_node.arn
      },
      {
        Sid    = "AllowInterruptionQueue"
        Effect = "Allow"
        Action = [
          "sqs:DeleteMessage", "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl", "sqs:ReceiveMessage"
        ]
        Resource = aws_sqs_queue.karpenter_interruption[0].arn
      },
      {
        Sid      = "AllowEKSAccess"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.main.arn
      },
      {
        Sid    = "AllowInstanceProfileAccess"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile", "iam:CreateInstanceProfile",
          "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile"
        ]
        Resource = "*"
      },
      {
        Sid      = "AllowPricing"
        Effect   = "Allow"
        Action   = ["pricing:GetProducts"]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# SQS Interruption Queue
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "karpenter_interruption" {
  count                     = var.enable_karpenter ? 1 : 0
  name                      = "${local.cluster_id}-karpenter"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  count     = var.enable_karpenter ? 1 : 0
  queue_url = aws_sqs_queue.karpenter_interruption[0].url
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = ["events.amazonaws.com", "sqs.amazonaws.com"] }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.karpenter_interruption[0].arn
    }]
  })
}

# -----------------------------------------------------------------------------
# Node Instance Profile
#
# Auto Mode creates the instance profile implicitly; open-source Karpenter
# requires it to exist as an explicit resource.
# -----------------------------------------------------------------------------
resource "aws_iam_instance_profile" "karpenter_node" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.cluster_id}-karpenter-node"
  role  = aws_iam_role.eks_auto_mode_node.name
}

# -----------------------------------------------------------------------------
# KMS Grant for Node Role
#
# RHEL AMI EBS volumes are encrypted with a CMK in the build account.
# Each target account's node role must be allowed to use that key.
# -----------------------------------------------------------------------------
resource "aws_iam_role_policy" "karpenter_node_kms" {
  count = var.enable_karpenter && var.ami_kms_key_arn != "" ? 1 : 0
  name  = "karpenter-node-kms-cross-account"
  role  = aws_iam_role.eks_auto_mode_node.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:CreateGrant", "kms:DescribeKey"]
      Resource = var.ami_kms_key_arn
    }]
  })
}

# EC2 Fleet uses the Karpenter controller role's IAM context (not the node instance
# profile) when calling KMS during cross-account snapshot-to-volume copy at launch time.
# The controller role therefore needs decrypt and re-encrypt permissions on the AMI key
# in addition to CreateGrant, which the node role handles at runtime.
resource "aws_iam_role_policy" "karpenter_controller_kms" {
  count = var.enable_karpenter && var.ami_kms_key_arn != "" ? 1 : 0
  name  = "karpenter-controller-kms-cross-account"
  role  = aws_iam_role.karpenter_controller[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCrossAccountAMIKeyOps"
        Effect = "Allow"
        Action = [
          "kms:DescribeKey",
          "kms:Decrypt",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
        ]
        Resource = var.ami_kms_key_arn
      },
      {
        # kms:GrantIsForAWSResource is only set on CreateGrant calls, not on crypto ops.
        Sid    = "AllowCrossAccountAMIKeyGrant"
        Effect = "Allow"
        Action = ["kms:CreateGrant"]
        Resource = var.ami_kms_key_arn
        Condition = {
          Bool = { "kms:GrantIsForAWSResource" = "true" }
        }
      },
    ]
  })
}

# -----------------------------------------------------------------------------
# EBS CSI Driver IRSA
#
# Allows the aws-ebs-csi-driver addon's controller ServiceAccount to call EBS
# APIs for volume provisioning. Required because Auto Mode block storage is
# disabled — the standard ebs.csi.aws.com provisioner handles PVC lifecycle
# with zone-based topology instead of compute-type=auto topology.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "ebs_csi_controller" {
  count = var.enable_karpenter ? 1 : 0
  name  = "${local.cluster_id}-ebs-csi-controller"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.eks[0].arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          "${replace(aws_iam_openid_connect_provider.eks[0].url, "https://", "")}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_controller" {
  count      = var.enable_karpenter ? 1 : 0
  role       = aws_iam_role.ebs_csi_controller[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}