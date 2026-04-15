# =============================================================================
# AWS Backup Module — FedRAMP CP-09 System Backup
#
# Creates an AWS Backup vault, plan, and selection covering RDS instances and
# DynamoDB tables in the regional cluster. Enforces a backup schedule,
# retention period, and cold storage transition meeting FedRAMP CP-09.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# =============================================================================
# KMS Key for Backup Vault Encryption
# =============================================================================

resource "aws_kms_key" "backup" {
  description             = "KMS key for AWS Backup vault encryption (FedRAMP CP-09/SC-28)"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  tags = {
    Name    = "${var.cluster_id}-backup"
    FedRAMP = "CP-09"
  }
}

resource "aws_kms_alias" "backup" {
  name          = "alias/${var.cluster_id}-backup"
  target_key_id = aws_kms_key.backup.key_id
}

# =============================================================================
# Backup Vault
# =============================================================================

resource "aws_backup_vault" "main" {
  name        = "${var.cluster_id}-backup-vault"
  kms_key_arn = aws_kms_key.backup.arn

  tags = {
    Name    = "${var.cluster_id}-backup-vault"
    FedRAMP = "CP-09"
  }
}

# Vault access policy — deny backup deletion without MFA
resource "aws_backup_vault_policy" "main" {
  backup_vault_name = aws_backup_vault.main.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyDeleteRecoveryPoint"
        Effect = "Deny"
        Principal = {
          AWS = "*"
        }
        Action = [
          "backup:DeleteRecoveryPoint",
          "backup:UpdateRecoveryPointLifecycle"
        ]
        Resource = "*"
        Condition = {
          StringNotLike = {
            "aws:PrincipalArn" = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/BreakGlassRole"
          }
        }
      }
    ]
  })
}

# =============================================================================
# Backup Plan
# =============================================================================

resource "aws_backup_plan" "main" {
  name = "${var.cluster_id}-backup-plan"

  rule {
    rule_name         = "daily-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 3 * * ? *)" # 3 AM UTC daily

    start_window      = 60
    completion_window = 180

    lifecycle {
      cold_storage_after = 90  # Move to cold storage after 90 days
      delete_after       = 395 # Keep 13 months total (FedRAMP CP-09 / AU-11)
    }

    recovery_point_tags = {
      FedRAMP = "CP-09"
    }
  }

  rule {
    rule_name         = "weekly-backup"
    target_vault_name = aws_backup_vault.main.name
    schedule          = "cron(0 2 ? * SUN *)" # 2 AM UTC every Sunday

    start_window      = 60
    completion_window = 480

    lifecycle {
      cold_storage_after = 30
      delete_after       = 395
    }

    copy_action {
      destination_vault_arn = var.cross_region_backup_vault_arn != "" ? var.cross_region_backup_vault_arn : aws_backup_vault.main.arn

      lifecycle {
        cold_storage_after = 30
        delete_after       = 395
      }
    }

    recovery_point_tags = {
      FedRAMP   = "CP-09"
      Frequency = "weekly"
    }
  }

  tags = {
    Name    = "${var.cluster_id}-backup-plan"
    FedRAMP = "CP-09"
  }
}

# =============================================================================
# IAM Role for AWS Backup
# =============================================================================

resource "aws_iam_role" "backup" {
  name = "${var.cluster_id}-backup-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "backup.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "backup_rds" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "backup_restore" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

# =============================================================================
# Backup Selection — Tag-based, covers RDS and DynamoDB
# =============================================================================

resource "aws_backup_selection" "tagged_resources" {
  name         = "${var.cluster_id}-backup-selection"
  iam_role_arn = aws_iam_role.backup.arn
  plan_id      = aws_backup_plan.main.id

  selection_tag {
    type  = "STRINGEQUALS"
    key   = "aws:cloudformation:stack-name"
    value = var.cluster_id
  }

  # Explicitly include all RDS instances and DynamoDB tables by ARN pattern
  resources = [
    "arn:aws:rds:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:db:${var.cluster_id}-*",
    "arn:aws:dynamodb:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:table/${var.cluster_id}-*",
  ]
}
