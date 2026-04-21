# =============================================================================
# Continuous Monitoring Module — FedRAMP CA-07
#
# Enables AWS Config (configuration recorder + managed rules) and GuardDuty
# (threat detection).
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# =============================================================================
# S3 Bucket for AWS Config Delivery
# =============================================================================

resource "aws_s3_bucket" "config" {
  bucket        = "${var.cluster_id}-config-${data.aws_caller_identity.current.account_id}"
  force_destroy = false

  tags = {
    Name    = "${var.cluster_id}-config"
    FedRAMP = "CA-07"
  }
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_kms_key" "s3_cmk" {
  description             = "CMK for Config S3 bucket SSE-KMS (FedRAMP SC-28)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowConfigRole"
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_role.config.arn
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
    Name    = "${var.cluster_id}-config-s3-cmk"
    FedRAMP = "SC-28"
  }
}

resource "aws_kms_alias" "s3_cmk" {
  name          = "alias/${var.cluster_id}-config-s3"
  target_key_id = aws_kms_key.s3_cmk.key_id
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3_cmk.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket = aws_s3_bucket.config.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    id     = "config-retention"
    status = "Enabled"

    transition {
      days          = 365
      storage_class = "GLACIER"
    }

    expiration {
      days = 1095
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigBucketPermissionsCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:config:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      },
      {
        Sid    = "AWSConfigBucketDelivery"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:config:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

# =============================================================================
# IAM Role for AWS Config
# =============================================================================

resource "aws_iam_role" "config" {
  name = "${var.cluster_id}-config-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action = "sts:AssumeRole"
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:config:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:*"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  role = aws_iam_role.config.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/Config/*"
      },
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:GenerateDataKey",
          "kms:Decrypt",
          "kms:Encrypt"
        ]
        Resource = aws_kms_key.s3_cmk.arn
      }
    ]
  })
}

# =============================================================================
# AWS Config — Configuration Recorder and Delivery Channel
# =============================================================================

resource "aws_config_configuration_recorder" "main" {
  name     = "${var.cluster_id}-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}

resource "aws_config_delivery_channel" "main" {
  name           = "${var.cluster_id}-config-delivery"
  s3_bucket_name = aws_s3_bucket.config.id

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [
    aws_config_delivery_channel.main,
    aws_s3_bucket_policy.config,
    aws_s3_bucket_server_side_encryption_configuration.config,
    aws_iam_role.config,
    aws_iam_role_policy_attachment.config_managed,
    aws_iam_role_policy.config_s3,
  ]
}

# =============================================================================
# AWS Config Managed Rules (FedRAMP CA-07)
# =============================================================================

resource "aws_config_config_rule" "eks_secrets_encrypted" {
  name        = "${var.cluster_id}-eks-secrets-encrypted"
  description = "FedRAMP CA-07/SC-28: Checks EKS clusters have secrets encrypted"

  source {
    owner             = "AWS"
    source_identifier = "EKS_SECRETS_ENCRYPTED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "rds_storage_encrypted" {
  name        = "${var.cluster_id}-rds-storage-encrypted"
  description = "FedRAMP CA-07/SC-28: Checks RDS instances are encrypted at rest"

  source {
    owner             = "AWS"
    source_identifier = "RDS_STORAGE_ENCRYPTED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "s3_bucket_public_read_prohibited" {
  name        = "${var.cluster_id}-s3-no-public-read"
  description = "FedRAMP CA-07: Checks S3 buckets do not allow public read access"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "kms_cmk_not_scheduled_deletion" {
  name        = "${var.cluster_id}-kms-cmk-not-scheduled-deletion"
  description = "FedRAMP CA-07/SC-28: Checks KMS CMKs are not scheduled for deletion"

  source {
    owner             = "AWS"
    source_identifier = "KMS_CMK_NOT_SCHEDULED_FOR_DELETION"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

resource "aws_config_config_rule" "cloudtrail_enabled" {
  name        = "${var.cluster_id}-cloudtrail-enabled"
  description = "FedRAMP CA-07/AU-12: Checks CloudTrail is enabled"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]
}

# =============================================================================
# GuardDuty (FedRAMP CA-07 / SI-03)
# =============================================================================

resource "aws_guardduty_detector" "main" {
  enable = true

  tags = {
    Name    = "${var.cluster_id}-guardduty"
    FedRAMP = "CA-07"
  }
}

resource "aws_guardduty_detector_feature" "s3_data_events" {
  detector_id = aws_guardduty_detector.main.id
  name        = "S3_DATA_EVENTS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "eks_audit_logs" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_AUDIT_LOGS"
  status      = "ENABLED"
}

resource "aws_guardduty_detector_feature" "ebs_malware_protection" {
  detector_id = aws_guardduty_detector.main.id
  name        = "EBS_MALWARE_PROTECTION"
  status      = "ENABLED"
}

# EKS Runtime Monitoring for GuardDuty
# Caller-controlled toggle via var.enable_eks_runtime_monitoring — not an AWS regional availability restriction.
resource "aws_guardduty_detector_feature" "eks_runtime_monitoring" {
  count       = var.enable_eks_runtime_monitoring ? 1 : 0
  detector_id = aws_guardduty_detector.main.id
  name        = "EKS_RUNTIME_MONITORING"
  status      = "ENABLED"

  additional_configuration {
    name   = "EKS_ADDON_MANAGEMENT"
    status = "ENABLED"
  }
}
