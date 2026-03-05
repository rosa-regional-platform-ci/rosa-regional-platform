# =============================================================================
# Maestro Agent IoT Provisioning Module - Variables
# =============================================================================

variable "management_cluster_id" {
  description = "Management cluster identifier (e.g., 'mc01'). This is used as the consumer name and for IoT resource naming."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.management_cluster_id))
    error_message = "management_cluster_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "mqtt_topic_prefix" {
  description = "MQTT topic prefix used in regional IoT Core. Must match the prefix configured in the Maestro Server."
  type        = string
  default     = "sources/maestro/consumers"
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
