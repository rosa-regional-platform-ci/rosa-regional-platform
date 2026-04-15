variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string
}

variable "kms_key_id" {
  description = "KMS key ID for SNS topic encryption at rest"
  type        = string
  default     = "alias/aws/sns"
}

variable "alert_email" {
  description = "Email address to receive security alert notifications (leave empty to skip email subscription)"
  type        = string
  default     = ""
}

variable "enable_security_hub_standards" {
  description = "Enable Security Hub NIST 800-53 v5 and CIS 1.4 standards subscriptions. Set to false for AWS regions that do not support these specific standards (e.g., some EU/AP regions). The standards are available in us-east-1, us-east-2, us-west-1, us-west-2, and most commercial regions but coverage varies."
  type        = bool
  default     = true
}
