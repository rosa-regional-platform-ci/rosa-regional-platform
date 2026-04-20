variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string
}

variable "kms_key_id" {
  description = "Customer-managed KMS key ID or ARN for SNS topic encryption at rest (required for FedRAMP SC-28). Must not be the AWS-managed alias/aws/sns."
  type        = string

  validation {
    condition     = var.kms_key_id != "alias/aws/sns" && length(var.kms_key_id) > 0
    error_message = "kms_key_id must be a customer-managed KMS key ARN or alias, not the AWS-managed alias/aws/sns."
  }
}

variable "alert_email" {
  description = "Email address to receive security alert notifications (leave empty to skip email subscription)"
  type        = string
  default     = ""
}

variable "cloudtrail_log_group" {
  description = "CloudWatch log group name where CloudTrail events are delivered (e.g. aws-controltower/CloudTrailLogs in the management account, or a regional trail group in member accounts). Must be non-empty."
  type        = string
  default     = "aws-controltower/CloudTrailLogs"

  validation {
    condition     = length(trimspace(var.cloudtrail_log_group)) > 0
    error_message = "cloudtrail_log_group must be a non-empty log group name."
  }
}

variable "enable_security_hub_standards" {
  description = "Enable Security Hub NIST 800-53 v5 and CIS 1.4 standards subscriptions. Set to false for AWS regions that do not support these specific standards (e.g., some EU/AP regions). The standards are available in us-east-1, us-east-2, us-west-1, us-west-2, and most commercial regions but coverage varies."
  type        = bool
  default     = true
}
