# =============================================================================
# Security Monitoring Module
#
# FedRAMP Moderate controls:
#   AU-06 — Audit Record Review, Analysis, and Reporting
#   CA-07 — Continuous Monitoring
#
# Enables AWS Security Hub (with CIS and NIST 800-53 standards), CloudWatch
# metric filters on EKS audit logs for unauthorized API calls, and SNS alarms
# to alert on suspicious activity.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# Look up the EKS cluster log group so Terraform verifies it exists before
# creating metric filters that reference it.
data "aws_cloudwatch_log_group" "eks_cluster" {
  name = "/aws/eks/${var.cluster_id}/cluster"
}



# =============================================================================
# KMS Key for SNS Topic Encryption (FedRAMP SC-28)
# =============================================================================

resource "aws_kms_key" "sns" {
  description             = "CMK for security-monitoring SNS topic encryption (FedRAMP SC-28)"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowSNS"
        Effect = "Allow"
        Principal = {
          Service = "sns.amazonaws.com"
        }
        Action = [
          "kms:GenerateDataKey*",
          "kms:Decrypt"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.cluster_id}-security-alerts-sns"
  }
}

resource "aws_kms_alias" "sns" {
  name          = "alias/${var.cluster_id}-security-alerts-sns"
  target_key_id = aws_kms_key.sns.key_id
}

# =============================================================================
# SNS Topic for Security Alerts
# =============================================================================

resource "aws_sns_topic" "security_alerts" {
  name              = "${var.cluster_id}-security-alerts"
  kms_master_key_id = aws_kms_key.sns.arn

  tags = {
    Name = "${var.cluster_id}-security-alerts"
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn = aws_sns_topic.security_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAlarms"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.security_alerts.arn
        Condition = {
          StringEquals = {
            "aws:SourceAccount" = data.aws_caller_identity.current.account_id
          }
          ArnLike = {
            "aws:SourceArn" = [
              aws_cloudwatch_metric_alarm.eks_unauthorized_api_calls.arn,
              aws_cloudwatch_metric_alarm.console_signin_failure.arn,
            ]
          }
        }
      },
      {
        # EventBridge (events.amazonaws.com) delivers Security Hub findings to
        # this topic via aws_cloudwatch_event_target.securityhub_alerts.
        # Without this statement the event target is silently denied.
        Sid    = "AllowEventBridge"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.security_alerts.arn
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  count     = var.alert_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Supports PagerDuty (https), SQS, or Lambda endpoints.
# For PagerDuty: set notification_protocol = "https" and notification_endpoint
# to your PagerDuty Events API v2 integration URL.
resource "aws_sns_topic_subscription" "security_alerts_notification" {
  count     = var.notification_endpoint != "" ? 1 : 0
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = var.notification_protocol
  endpoint  = var.notification_endpoint
}

# =============================================================================
# AU-06: CloudWatch Metric Filters — EKS Unauthorized API Calls
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "eks_unauthorized_api_calls" {
  alarm_name          = "${var.cluster_id}-eks-unauthorized-api-calls"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "EKSUnauthorizedAPICalls"
  namespace           = "FedRAMP/${var.cluster_id}"
  period              = 300
  statistic           = "Sum"
  threshold           = 5
  alarm_description   = "FedRAMP AU-06: EKS audit log unauthorized API call rate exceeded threshold"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
  ok_actions          = [aws_sns_topic.security_alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = {
    Name    = "${var.cluster_id}-eks-unauthorized-api-calls"
    FedRAMP = "AU-06"
  }
}

resource "aws_cloudwatch_log_metric_filter" "eks_unauthorized_api_calls" {
  name           = "${var.cluster_id}-eks-unauthorized-api-calls"
  pattern        = "{ ($.responseStatus.code = 401) || ($.responseStatus.code = 403) }"
  log_group_name = data.aws_cloudwatch_log_group.eks_cluster.name

  metric_transformation {
    name          = "EKSUnauthorizedAPICalls"
    namespace     = "FedRAMP/${var.cluster_id}"
    value         = "1"
    default_value = "0"
  }
}

# =============================================================================
# AU-06: CloudWatch Metric Filter — Console Sign-In Failures
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "console_signin_failure" {
  alarm_name          = "${var.cluster_id}-console-signin-failures"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  metric_name         = "ConsoleSignInFailures"
  namespace           = "FedRAMP/${var.cluster_id}"
  period              = 300
  statistic           = "Sum"
  threshold           = 3
  alarm_description   = "FedRAMP AU-06: Multiple AWS Console sign-in failures detected"
  alarm_actions       = [aws_sns_topic.security_alerts.arn]
  ok_actions          = [aws_sns_topic.security_alerts.arn]
  treat_missing_data  = "notBreaching"

  tags = {
    Name    = "${var.cluster_id}-console-signin-failures"
    FedRAMP = "AU-06"
  }
}

resource "aws_cloudwatch_log_metric_filter" "console_signin_failure" {
  count          = var.cloudtrail_log_group != "" ? 1 : 0
  name           = "${var.cluster_id}-console-signin-failures"
  pattern        = "{ ($.eventName = ConsoleLogin) && ($.responseElements.ConsoleLogin = \"Failure\") }"
  log_group_name = var.cloudtrail_log_group

  metric_transformation {
    name          = "ConsoleSignInFailures"
    namespace     = "FedRAMP/${var.cluster_id}"
    value         = "1"
    default_value = "0"
  }
}

# =============================================================================
# AU-06 / CA-07: AWS Security Hub
# =============================================================================

resource "aws_securityhub_account" "main" {
  # Security Hub is an account-level singleton. If already enabled (e.g. by a
  # prior environment or org policy), Terraform import is required rather than
  # recreation. ignore_changes prevents spurious conflicts on re-apply.
  lifecycle {
    ignore_changes = all
  }
}

# NIST 800-53 v5 and CIS 1.4 standards are not available in all AWS regions.
# Use var.enable_security_hub_standards = false for regions that do not support them.
resource "aws_securityhub_standards_subscription" "nist_800_53" {
  count         = var.enable_security_hub_standards ? 1 : 0
  depends_on    = [aws_securityhub_account.main]
  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.id}::standards/nist-800-53/v/5.0.0"
}

resource "aws_securityhub_standards_subscription" "cis_aws" {
  count         = var.enable_security_hub_standards ? 1 : 0
  depends_on    = [aws_securityhub_account.main]
  standards_arn = "arn:${data.aws_partition.current.partition}:securityhub:${data.aws_region.current.id}::standards/cis-aws-foundations-benchmark/v/1.4.0"
}

# Export Security Hub findings to SNS via EventBridge
resource "aws_cloudwatch_event_rule" "securityhub_high_findings" {
  name        = "${var.cluster_id}-securityhub-high-findings"
  description = "FedRAMP AU-06/CA-07: Alert on Security Hub HIGH or CRITICAL findings"

  event_pattern = jsonencode({
    source      = ["aws.securityhub"]
    detail-type = ["Security Hub Findings - Imported"]
  })

  tags = {
    Name    = "${var.cluster_id}-securityhub-high-findings"
    FedRAMP = "AU-06"
  }
}

resource "aws_cloudwatch_event_target" "securityhub_alerts" {
  rule      = aws_cloudwatch_event_rule.securityhub_high_findings.name
  target_id = "SecurityAlertsSNS"
  arn       = aws_sns_topic.security_alerts.arn
}
