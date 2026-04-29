variable "slack_webhook_ssm_param" {
  type        = string
  description = "SSM Parameter Store path containing the Slack webhook URL (e.g., '/rosa-regional/slack/webhook-url')"
}

variable "name_prefix" {
  type        = string
  description = "Prefix for resource names (e.g., 'abc123-' or empty string)"
  default     = ""
}

variable "region" {
  type        = string
  description = "AWS Region for the notification resources"
}

variable "pipeline_names" {
  type        = list(string)
  description = "List of CodePipeline names to monitor for failures. Only failures from these pipelines will trigger notifications."
}

