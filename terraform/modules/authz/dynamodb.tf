# =============================================================================
# DynamoDB Tables for ROSA Authorization
#
# Tables:
# - accounts:    Account provisioning and policy store mapping
# - admins:      Admin bypass for accounts
# - groups:      Authorization groups
# - members:     Group membership (with GSI for user->groups lookup)
# - policies:    Policy templates
# - attachments: Policy attachments to users/groups (with GSIs)
# =============================================================================

# =============================================================================
# Accounts Table
# =============================================================================
# Stores enabled accounts with their AVP policy store IDs
# PK: accountId

resource "aws_dynamodb_table" "accounts" {
  name                        = local.table_names.accounts
  billing_mode                = var.billing_mode
  hash_key                    = "accountId"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "accountId"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_names.accounts
      Component = "authz"
    }
  )
}

# =============================================================================
# Admins Table
# =============================================================================
# Stores admin principals that bypass Cedar authorization for an account
# PK: accountId, SK: principalArn

resource "aws_dynamodb_table" "admins" {
  name                        = local.table_names.admins
  billing_mode                = var.billing_mode
  hash_key                    = "accountId"
  range_key                   = "principalArn"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "principalArn"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_names.admins
      Component = "authz"
    }
  )
}

# =============================================================================
# Groups Table
# =============================================================================
# Stores authorization groups for an account
# PK: accountId, SK: groupId

resource "aws_dynamodb_table" "groups" {
  name                        = local.table_names.groups
  billing_mode                = var.billing_mode
  hash_key                    = "accountId"
  range_key                   = "groupId"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "groupId"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_names.groups
      Component = "authz"
    }
  )
}

# =============================================================================
# Group Members Table
# =============================================================================
# Stores group membership with GSI for reverse lookup (user -> groups)
# PK: accountId, SK: groupId#memberArn
# GSI: member-groups-index (PK: accountId#memberArn, SK: groupId)

resource "aws_dynamodb_table" "members" {
  name                        = local.table_names.members
  billing_mode                = var.billing_mode
  hash_key                    = "accountId"
  range_key                   = "groupId#memberArn"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "groupId#memberArn"
    type = "S"
  }

  attribute {
    name = "accountId#memberArn"
    type = "S"
  }

  attribute {
    name = "groupId"
    type = "S"
  }

  # GSI for looking up which groups a user belongs to
  global_secondary_index {
    name            = "member-groups-index"
    hash_key        = "accountId#memberArn"
    range_key       = "groupId"
    projection_type = "ALL"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_names.members
      Component = "authz"
    }
  )
}

# =============================================================================
# Policies Table
# =============================================================================
# Stores policy templates (v0 format) without principals
# PK: accountId, SK: policyId

resource "aws_dynamodb_table" "policies" {
  name                        = local.table_names.policies
  billing_mode                = var.billing_mode
  hash_key                    = "accountId"
  range_key                   = "policyId"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "policyId"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_names.policies
      Component = "authz"
    }
  )
}

# =============================================================================
# Attachments Table
# =============================================================================
# Stores policy attachments to users or groups
# PK: accountId, SK: attachmentId
# GSI: target-index (lookup attachments by target)
# GSI: policy-index (lookup attachments by policy)

resource "aws_dynamodb_table" "attachments" {
  name                        = local.table_names.attachments
  billing_mode                = var.billing_mode
  hash_key                    = "accountId"
  range_key                   = "attachmentId"
  deletion_protection_enabled = var.enable_deletion_protection

  attribute {
    name = "accountId"
    type = "S"
  }

  attribute {
    name = "attachmentId"
    type = "S"
  }

  attribute {
    name = "accountId#targetType#targetId"
    type = "S"
  }

  attribute {
    name = "policyId"
    type = "S"
  }

  attribute {
    name = "accountId#policyId"
    type = "S"
  }

  # GSI for looking up attachments by target (user or group)
  global_secondary_index {
    name            = "target-index"
    hash_key        = "accountId#targetType#targetId"
    range_key       = "policyId"
    projection_type = "ALL"
  }

  # GSI for looking up attachments by policy
  global_secondary_index {
    name            = "policy-index"
    hash_key        = "accountId#policyId"
    range_key       = "attachmentId"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  tags = merge(
    local.common_tags,
    {
      Name      = local.table_names.attachments
      Component = "authz"
    }
  )
}

# =============================================================================
# FedRAMP SC-28: KMS Customer-Managed Key for DynamoDB Encryption
# =============================================================================
# NOTE: DynamoDB table server_side_encryption blocks with customer_master_key_id
# are added to each table below via a separate CMK resource. The existing tables
# above use point_in_time_recovery but lack CMK encryption; the KMS key below
# enables that. A table replacement (destroy/create) is required to change the
# CMK on an existing table — plan this during a maintenance window.

resource "aws_kms_key" "dynamodb" {
  description             = "KMS CMK for ROSA authz DynamoDB tables encryption at rest (FedRAMP SC-28)"
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
        Sid    = "AllowDynamoDB"
        Effect = "Allow"
        Principal = {
          Service = "dynamodb.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = merge(
    local.common_tags,
    {
      Name      = "${local.table_names.accounts}-kms"
      Component = "authz"
      FedRAMP   = "SC-28"
    }
  )
}

resource "aws_kms_alias" "dynamodb" {
  name          = "alias/${var.regional_id}-authz-dynamodb"
  target_key_id = aws_kms_key.dynamodb.key_id
}
