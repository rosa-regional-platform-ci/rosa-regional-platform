# =============================================================================
# IAM Roles for Hosted Control Plane Components
#
# One role per control plane component, all using OIDC-federated trust.
# Each role's trust policy restricts access to a specific Kubernetes
# service account via the sub and aud claims.
#
# Permission policies use AWS-managed ROSA policies, which are maintained
# by AWS and automatically updated when OpenShift needs new API access.
# =============================================================================

resource "aws_iam_role" "hosted_control_plane" {
  for_each = local.roles

  name        = "${var.cluster_name}-${each.key}"
  description = each.value.description

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = aws_iam_openid_connect_provider.hosted_cluster.arn
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:${each.value.sa_namespace}:${each.value.sa_name}"
          "${local.oidc_issuer}:aud" = "openshift"
        }
      }
    }]
  })

  tags = merge(
    local.common_tags,
    {
      Name = "${var.cluster_name}-${each.key}"
    }
  )
}

# =============================================================================
# AWS-Managed ROSA Policies
#
# These are maintained by AWS and automatically updated when OpenShift/ROSA
# needs new permissions. Using managed policies avoids drift and eliminates
# the need to manually sync policy documents with HyperShift releases.
# =============================================================================

locals {
  managed_policies = {
    ingress                  = "arn:aws:iam::aws:policy/service-role/ROSAIngressOperatorPolicy"
    cloud-controller-manager = "arn:aws:iam::aws:policy/service-role/ROSAKubeControllerPolicy"
    ebs-csi                  = "arn:aws:iam::aws:policy/service-role/ROSAAmazonEBSCSIDriverOperatorPolicy"
    image-registry           = "arn:aws:iam::aws:policy/service-role/ROSAImageRegistryOperatorPolicy"
    network-config           = "arn:aws:iam::aws:policy/service-role/ROSACloudNetworkConfigOperatorPolicy"
    control-plane-operator   = "arn:aws:iam::aws:policy/service-role/ROSAControlPlaneOperatorPolicy"
    node-pool-management     = "arn:aws:iam::aws:policy/service-role/ROSANodePoolManagementPolicy"
  }
}

resource "aws_iam_role_policy_attachment" "managed_policy" {
  for_each   = local.managed_policies
  role       = aws_iam_role.hosted_control_plane[each.key].name
  policy_arn = each.value
}

# =============================================================================
# Supplemental CPO Policy — Permissions Not in v5 ROSAControlPlaneOperatorPolicy
#
# The v5 managed policy now covers most EC2 security group, VPC endpoint, and
# Route53 permissions (conditioned on red-hat-managed=true tag). This
# supplemental policy only fills genuine gaps:
#   - ec2:DescribeVpcEndpointServices: needed by awsprivatelink controller
#   - ec2:DescribeSubnets: not in managed policy read permissions
#   - route53:GetHostedZone / ListHostedZonesByName: needed to look up the
#     {cluster}.hypershift.local zone (created by terraform, not CPO)
# =============================================================================

resource "aws_iam_role_policy" "cpo_supplemental" {
  name = "${var.cluster_name}-cpo-supplemental"
  role = aws_iam_role.hosted_control_plane["control-plane-operator"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "VpcEndpointServiceDiscovery"
        Effect = "Allow"
        Action = [
          "ec2:DescribeVpcEndpointServices",
          "ec2:DescribeSubnets",
        ]
        Resource = "*"
      },
      {
        Sid    = "Route53ZoneLookup"
        Effect = "Allow"
        Action = [
          "route53:GetHostedZone",
          "route53:ListHostedZonesByName",
        ]
        Resource = "*"
      },
    ]
  })
}

# =============================================================================
# Supplemental Node Pool Management Policy — DescribeInstanceTypes
#
# The managed ROSANodePoolManagementPolicy v8 does not include
# ec2:DescribeInstanceTypes. The CAPI provider uses this to determine instance
# architecture (arm64 vs x86_64). Without it, CAPI falls back to x86_64 and
# generates log errors.
#
# iam:PassRole is no longer needed here because the worker role is now named
# {cluster}-ROSA-Worker-Role, which matches the managed policy's condition:
#   "Resource": ["arn:*:iam::*:role/*-ROSA-Worker-Role"]
# =============================================================================

resource "aws_iam_role_policy" "node_pool_supplemental" {
  name = "${var.cluster_name}-node-pool-supplemental"
  role = aws_iam_role.hosted_control_plane["node-pool-management"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DescribeInstanceTypes"
        Effect = "Allow"
        Action = "ec2:DescribeInstanceTypes"
        Resource = "*"
      },
    ]
  })
}
