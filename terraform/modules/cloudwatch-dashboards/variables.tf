# =============================================================================
# Required Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name for CloudWatch metrics dimensions"
  type        = string
}

variable "platform_api_gateway_id" {
  description = "Platform API Gateway REST API ID"
  type        = string
}

variable "platform_api_stage_name" {
  description = "Platform API Gateway stage name"
  type        = string
}

variable "rhobs_api_gateway_id" {
  description = "RHOBS API Gateway REST API ID"
  type        = string
}

variable "rhobs_api_stage_name" {
  description = "RHOBS API Gateway stage name"
  type        = string
  default     = "prod"
}

variable "maestro_rds_identifier" {
  description = "Maestro RDS instance identifier"
  type        = string
}

variable "hyperfleet_rds_identifier" {
  description = "HyperFleet RDS instance identifier"
  type        = string
}

# =============================================================================
# Optional Variables
# =============================================================================

variable "dashboard_period" {
  description = "Default period in seconds for dashboard widgets"
  type        = number
  default     = 300

  validation {
    condition     = contains([60, 300, 900, 3600], var.dashboard_period)
    error_message = "Dashboard period must be one of: 60, 300, 900, 3600."
  }
}
