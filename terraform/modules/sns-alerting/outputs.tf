# =============================================================================
# Outputs
# =============================================================================

output "sns_topic_arn" {
  description = "ARN of the SNS topic for alert fan-out"
  value       = aws_sns_topic.alerts.arn
}

output "sns_topic_name" {
  description = "Name of the SNS topic for alert fan-out"
  value       = aws_sns_topic.alerts.name
}

output "kms_key_arn" {
  description = "ARN of the KMS key used to encrypt the SNS topic"
  value       = aws_kms_key.sns_alerts.arn
}

output "webhook_bridge_role_arn" {
  description = "IAM role ARN for the webhook bridge service"
  value       = aws_iam_role.webhook_bridge.arn
}

output "sns_topic_arn_parameter_name" {
  description = "SSM parameter name storing the SNS topic ARN"
  value       = aws_ssm_parameter.sns_topic_arn.name
}
