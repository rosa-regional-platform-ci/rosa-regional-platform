# =============================================================================
# Hosted Cluster IAM Module
#
# Creates IAM OIDC provider and roles for HyperShift hosted control plane
# components to assume via STS (AssumeRoleWithWebIdentity) in a customer
# AWS account.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  common_tags = merge(
    var.tags,
    {
      Module          = "hosted-cluster-iam"
      Cluster         = var.cluster_name
      ManagedBy       = "terraform"
      red-hat-managed = "true"
    }
  )

  # Full OIDC issuer URL: base URL + cluster name path
  oidc_issuer_url = "${var.oidc_base_url}/${var.cluster_name}"

  # Strip https:// for use in trust policy conditions
  oidc_issuer = trimprefix(local.oidc_issuer_url, "https://")

  # Control plane component role definitions
  roles = {
    ingress = {
      sa_namespace = "openshift-ingress-operator"
      sa_name      = "ingress-operator"
      description  = "Manages AWS ELBs/NLBs for OpenShift routes"
    }
    cloud-controller-manager = {
      sa_namespace = "kube-system"
      sa_name      = "kube-controller-manager"
      description  = "Manages load balancers and node lifecycle"
    }
    ebs-csi = {
      sa_namespace = "openshift-cluster-csi-drivers"
      sa_name      = "aws-ebs-csi-driver-controller-sa"
      description  = "Creates and attaches EBS volumes"
    }
    image-registry = {
      sa_namespace = "openshift-image-registry"
      sa_name      = "cluster-image-registry-operator"
      description  = "S3 access for the internal container image registry"
    }
    network-config = {
      sa_namespace = "openshift-cloud-network-config-controller"
      sa_name      = "cloud-credentials"
      description  = "Manages ENIs and cloud networking configuration"
    }
    control-plane-operator = {
      sa_namespace = "kube-system"
      sa_name      = "control-plane-operator"
      description  = "Control plane operator managing hosted cluster lifecycle"
    }
    node-pool-management = {
      sa_namespace = "kube-system"
      sa_name      = "capa-controller-manager"
      description  = "Node pool management for EC2 instance lifecycle"
    }
  }
}

# =============================================================================
# IAM OIDC Provider
#
# Trusts the CloudFront-backed OIDC issuer used by HyperShift on the
# management cluster. Control plane pods present tokens signed by this
# issuer when assuming roles via AssumeRoleWithWebIdentity.
#
# The TLS certificate thumbprint is fetched dynamically from the CloudFront
# endpoint at apply time, so it stays correct if Amazon rotates certificates.
# =============================================================================

data "tls_certificate" "oidc" {
  url = local.oidc_issuer_url
}

resource "aws_iam_openid_connect_provider" "hosted_cluster" {
  url = local.oidc_issuer_url

  client_id_list  = ["openshift"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-oidc-provider"
    }
  )
}

# =============================================================================
# Worker Node IAM Role and Instance Profile
#
# Standard EC2 instance profile (not OIDC-based) for hosted cluster worker
# nodes. Uses the AWS-managed ROSAWorkerInstancePolicy for ECR access and
# EC2 operations. SSM is added separately for break-glass debugging.
#
# The role name uses the *-ROSA-Worker-Role convention to match the
# ROSANodePoolManagementPolicy's iam:PassRole condition, avoiding the need
# for a supplemental PassRole policy.
# =============================================================================

resource "aws_iam_role" "worker_node" {
  name        = "${var.cluster_name}-ROSA-Worker-Role"
  description = "IAM role for hosted cluster worker node EC2 instances"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-ROSA-Worker-Role"
    }
  )
}

resource "aws_iam_instance_profile" "worker_node" {
  name = "${var.cluster_name}-ROSA-Worker-Role"
  role = aws_iam_role.worker_node.name

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-ROSA-Worker-Role"
    }
  )
}

resource "aws_iam_role_policy_attachment" "worker_rosa" {
  role       = aws_iam_role.worker_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/ROSAWorkerInstancePolicy"
}

resource "aws_iam_role_policy_attachment" "worker_ssm" {
  role       = aws_iam_role.worker_node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
