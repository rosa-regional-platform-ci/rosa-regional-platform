# =============================================================================
# Thanos Infrastructure Module
#
# Creates S3 bucket, KMS key, and IAM role for Thanos Receiver.
# This provides the minimum infrastructure needed to deploy Thanos.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  bucket_name = "${var.cluster_id}-thanos-metrics"
  role_name   = "${var.cluster_id}-thanos"

  # FIPS endpoints are only available in US regions and GovCloud
  fips_regions = ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "us-gov-east-1", "us-gov-west-1"]
  use_fips     = contains(local.fips_regions, data.aws_region.current.name)
  s3_endpoint  = local.use_fips ? "s3-fips.${data.aws_region.current.name}.amazonaws.com" : "s3.${data.aws_region.current.name}.amazonaws.com"
}

# =============================================================================
# KMS Key for S3 Encryption (FedRAMP Requirement)
# =============================================================================

resource "aws_kms_key" "thanos" {
  description             = "KMS key for Thanos metrics S3 bucket encryption"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowThanosRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.thanos_receiver.arn
        }
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.cluster_id}-thanos"
  }
}

resource "aws_kms_alias" "thanos" {
  name          = "alias/${var.cluster_id}-thanos"
  target_key_id = aws_kms_key.thanos.key_id
}

# =============================================================================
# S3 Bucket for Thanos Object Storage
# =============================================================================

resource "aws_s3_bucket" "thanos" {
  bucket = local.bucket_name

  # Warn about FedRAMP compliance when deploying to non-US regions
  lifecycle {
    precondition {
      condition     = local.use_fips || var.allow_non_fips_regions
      error_message = "FedRAMP compliance requires FIPS endpoints. Deploy to US regions (us-east-1, us-east-2, us-west-1, us-west-2) or set allow_non_fips_regions=true to override."
    }
  }

  tags = {
    Name = local.bucket_name
  }
}

resource "aws_s3_bucket_versioning" "thanos" {
  bucket = aws_s3_bucket.thanos.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "thanos" {
  bucket = aws_s3_bucket.thanos.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.thanos.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "thanos" {
  bucket = aws_s3_bucket.thanos.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "thanos" {
  bucket = aws_s3_bucket.thanos.id

  rule {
    id     = "expire-old-blocks"
    status = "Enabled"

    # Thanos compactor handles block lifecycle, but set a safety expiration
    expiration {
      days = var.metrics_retention_days
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }

    # Clean up incomplete multipart uploads after 7 days
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# =============================================================================
# IAM Role for Thanos Receiver (Pod Identity)
# =============================================================================

resource "aws_iam_role" "thanos_receiver" {
  name = local.role_name

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "pods.eks.amazonaws.com"
        }
        Action = [
          "sts:AssumeRole",
          "sts:TagSession"
        ]
      }
    ]
  })

  tags = {
    Name = local.role_name
  }
}

resource "aws_iam_role_policy" "thanos_s3" {
  name = "thanos-s3-access"
  role = aws_iam_role.thanos_receiver.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3BucketAccess"
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.thanos.arn
      },
      {
        Sid    = "S3ObjectAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject"
        ]
        Resource = "${aws_s3_bucket.thanos.arn}/*"
      },
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.thanos.arn
      }
    ]
  })
}

# =============================================================================
# EKS Pod Identity Associations
# =============================================================================

# Base service account (for manual deployments)
resource "aws_eks_pod_identity_association" "thanos_receiver" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.thanos_namespace
  service_account = var.thanos_service_account
  role_arn        = aws_iam_role.thanos_receiver.arn

  tags = {
    Name = "${var.cluster_id}-thanos"
  }
}

# Service accounts created by thanos-community operator
# These have predictable names based on the CR names following the pattern:
# - ThanosStore CR "thanos-store" → ServiceAccount "thanos-store-thanos-store"
# - ThanosCompact CR "thanos-compact" → ServiceAccount "thanos-compact-thanos-compact"
# - ThanosReceive CR "thanos-receive" with hashring "default" → ServiceAccount "thanos-receive-ingester-thanos-receive-default"
# If CR names change in Helm templates, update these service_account values accordingly.

# ThanosStore: Provides object storage access to query historical metrics
resource "aws_eks_pod_identity_association" "thanos_store" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.thanos_namespace
  service_account = "thanos-store-thanos-store"
  role_arn        = aws_iam_role.thanos_receiver.arn

  tags = {
    Name = "${var.cluster_id}-thanos-store"
  }
}

# ThanosCompact: Compacts and downsamples metrics in object storage
resource "aws_eks_pod_identity_association" "thanos_compact" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.thanos_namespace
  service_account = "thanos-compact-thanos-compact"
  role_arn        = aws_iam_role.thanos_receiver.arn

  tags = {
    Name = "${var.cluster_id}-thanos-compact"
  }
}

# ThanosReceive Ingester: Receives and stores metrics from remote_write endpoints
resource "aws_eks_pod_identity_association" "thanos_receive_ingester" {
  cluster_name    = var.eks_cluster_name
  namespace       = var.thanos_namespace
  service_account = "thanos-receive-ingester-thanos-receive-default"
  role_arn        = aws_iam_role.thanos_receiver.arn

  tags = {
    Name = "${var.cluster_id}-thanos-receive-ingester"
  }
}
