# =============================================================================
# Maestro Agent IoT Provisioning - Variables
# =============================================================================

# Management Cluster Identification
variable "management_cluster_id" {
  description = "Management cluster identifier (e.g., 'mc01')"
  type        = string
}

# MQTT Configuration
variable "mqtt_topic_prefix" {
  description = "MQTT topic prefix (must match regional cluster configuration)"
  type        = string
  default     = "sources/maestro/consumers"
}

# Tagging
variable "app_code" {
  description = "Application code for resource tagging and cost allocation"
  type        = string
}

variable "service_phase" {
  description = "Service phase (development, staging, production)"
  type        = string
}

variable "cost_center" {
  description = "Cost center identifier for billing and cost allocation"
  type        = string
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
