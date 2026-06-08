# =============================================================================
# ZOA Job Pod Identity (MC-side)
#
# Pod Identity role for ZOA Trusted Action jobs running on MCs.
# Jobs need cross-account S3 PutObject access to upload execution artifacts
# (execution.log, output.json) to the regional ZOA outputs bucket.
# =============================================================================

resource "aws_iam_role" "zoa_job" {
  name        = "${var.management_id}-zoa-job"
  description = "Pod Identity role for ZOA jobs to upload artifacts to regional S3 bucket"

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
    Name = "${var.management_id}-zoa-job"
  }
}

resource "aws_iam_role_policy" "zoa_job_s3" {
  name = "${var.management_id}-zoa-job-s3-upload"
  role = aws_iam_role.zoa_job.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "s3:PutObject"
      Resource = "${var.zoa_outputs_bucket_arn}/*"
    }]
  })
}

# One Pod Identity association per ZOA service account
resource "aws_eks_pod_identity_association" "zoa_kube" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-kube-sa"
  role_arn        = aws_iam_role.zoa_job.arn

  tags = {
    Name = "${var.management_id}-zoa-kube-pod-identity"
  }
}

resource "aws_eks_pod_identity_association" "zoa_aws_read" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-aws-read-sa"
  role_arn        = aws_iam_role.zoa_job.arn

  tags = {
    Name = "${var.management_id}-zoa-aws-read-pod-identity"
  }
}

resource "aws_eks_pod_identity_association" "zoa_aws_write" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-aws-write-sa"
  role_arn        = aws_iam_role.zoa_job.arn

  tags = {
    Name = "${var.management_id}-zoa-aws-write-pod-identity"
  }
}

resource "aws_eks_pod_identity_association" "zoa_breakglass_read" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-breakglass-read-sa"
  role_arn        = aws_iam_role.zoa_job.arn

  tags = {
    Name = "${var.management_id}-zoa-breakglass-read-pod-identity"
  }
}

resource "aws_eks_pod_identity_association" "zoa_breakglass_write" {
  cluster_name    = var.eks_cluster_name
  namespace       = "zoa-jobs"
  service_account = "zoa-breakglass-write-sa"
  role_arn        = aws_iam_role.zoa_job.arn

  tags = {
    Name = "${var.management_id}-zoa-breakglass-write-pod-identity"
  }
}
