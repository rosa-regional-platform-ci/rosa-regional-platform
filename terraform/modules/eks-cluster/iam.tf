# =============================================================================
# IAM Roles and Policies for EKS Cluster
#
# Creates IAM roles required for EKS operation:
# - Cluster service role with required permissions
# - Node group role for managed nodes
# =============================================================================

# -----------------------------------------------------------------------------
# EKS Cluster Service Role
# -----------------------------------------------------------------------------

resource "aws_iam_role" "eks_cluster" {
  name = "${local.cluster_id}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_cluster.name
}

# -----------------------------------------------------------------------------
# EKS Node Group Role
#
# Role assumed by managed node group EC2 instances.
# AmazonEKS_CNI_Policy is attached here; migrate to pod identity when ready.
# -----------------------------------------------------------------------------
resource "aws_iam_role" "eks_node_group" {
  name = "${local.cluster_id}-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_group_managed" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  ])
  policy_arn = each.value
  role       = aws_iam_role.eks_node_group.name
}