variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_id))
    error_message = "cluster_id must contain only lowercase letters, numbers, and hyphens and must not be empty."
  }
}


variable "alert_email" {
  description = "Email address to receive security alert notifications (leave empty to skip email subscription)"
  type        = string
  default     = ""

  validation {
    condition     = var.alert_email == "" || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alert_email))
    error_message = "alert_email must be empty or a valid email address."
  }
}

variable "cloudtrail_log_group" {
  description = "CloudWatch log group name where CloudTrail events are delivered (e.g. aws-controltower/CloudTrailLogs). Leave empty to disable the console sign-in failure metric filter."
  type        = string
  default     = ""
}

variable "notification_endpoint" {
  description = "Endpoint to receive security alert notifications. Use a PagerDuty Events API v2 HTTPS URL, an SQS ARN, or a Lambda ARN. Leave empty to disable. Pair with notification_protocol."
  type        = string
  default     = ""

  validation {
    condition = var.notification_endpoint == "" || can(regex("^https://", var.notification_endpoint)) || can(regex("^arn:[a-z0-9-]+:sqs:", var.notification_endpoint)) || can(regex("^arn:[a-z0-9-]+:lambda:", var.notification_endpoint))
    error_message = "notification_endpoint must be empty or a valid HTTPS URL (https://...), SQS ARN (arn:aws:sqs:...), or Lambda ARN (arn:aws:lambda:...)."
  }
}

variable "notification_protocol" {
  description = "SNS subscription protocol for notification_endpoint. One of: https (PagerDuty/Grafana/Jira webhook), sqs, lambda."
  type        = string
  default     = "https"

  validation {
    condition     = contains(["https", "sqs", "lambda"], var.notification_protocol)
    error_message = "notification_protocol must be one of: https, sqs, lambda."
  }
}

variable "enable_security_hub_standards" {
  description = "Enable Security Hub NIST 800-53 v5 and CIS 1.4 standards subscriptions. Set to false for AWS regions that do not support these specific standards (e.g., some EU/AP regions). The standards are available in us-east-1, us-east-2, us-west-1, us-west-2, and most commercial regions but coverage varies."
  type        = bool
  default     = true
}
