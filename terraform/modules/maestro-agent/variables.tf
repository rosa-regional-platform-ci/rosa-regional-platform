# =============================================================================
# Maestro Agent Module - Input Variables
# =============================================================================

variable "management_id" {
  description = "Management cluster identifier for resource naming (e.g., 'mc01')"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.management_id))
    error_message = "management_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "regional_aws_account_id" {
  description = "AWS account ID where the regional cluster and IoT Core are hosted"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.regional_aws_account_id))
    error_message = "regional_aws_account_id must be a 12-digit AWS account ID"
  }
}

variable "eks_cluster_name" {
  description = "Name of the EKS management cluster"
  type        = string
}

variable "mqtt_topic_prefix" {
  description = "MQTT topic prefix used in regional IoT Core"
  type        = string
  default     = "sources/maestro/consumers"
}

variable "maestro_agent_cert_json" {
  description = "Maestro agent certificate material as JSON string (from IoT Mint outputs)"
  type        = string
  sensitive   = true
}

variable "maestro_agent_config_json" {
  description = "Maestro agent MQTT configuration as JSON string (from IoT Mint outputs)"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
