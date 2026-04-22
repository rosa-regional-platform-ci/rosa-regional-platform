variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string
}

variable "api_gateway_stage_arn" {
  description = "ARN of the API Gateway stage to associate the WAF Web ACL with"
  type        = string
}

variable "rate_limit_per_5m_per_ip" {
  description = "Maximum number of requests allowed per IP in a 5-minute window before WAF blocks the IP"
  type        = number
  default     = 2000
}

variable "log_retention_in_days" {
  description = "CloudWatch log retention in days for WAF access logs"
  type        = number
  default     = 365
}

variable "blocked_requests_alarm_threshold" {
  description = "Number of blocked WAF requests in the evaluation period that triggers an alarm"
  type        = number
  default     = 100
}

variable "security_alerts_topic_arn" {
  description = "ARN of the SNS topic to receive WAF security alarm notifications. Leave empty to disable."
  type        = string
  default     = ""
}
