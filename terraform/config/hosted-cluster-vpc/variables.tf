# =============================================================================
# Hosted Cluster VPC Configuration - Variables
# =============================================================================

variable "cluster_name" {
  description = "Name of the hosted cluster (must match the HostedCluster CR name)"
  type        = string
}

# Default tags (matching other configs in this repo)
variable "app_code" {
  description = "Application code tag"
  type        = string
  default     = "ROSA"
}

variable "service_phase" {
  description = "Service phase tag"
  type        = string
  default     = "development"
}

variable "cost_center" {
  description = "Cost center tag"
  type        = string
  default     = "engineering"
}
