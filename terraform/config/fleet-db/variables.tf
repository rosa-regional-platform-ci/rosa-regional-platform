# =============================================================================
# Fleet-DB Infrastructure Variables
# =============================================================================

variable "fleet_db_id" {
  description = "Fleet-DB cluster identifier for resource naming (e.g., 'fleet-db' or 'xg4y-fleet-db' in CI)"
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.fleet_db_id))
    error_message = "fleet_db_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "environment" {
  description = "Environment name for tagging (e.g., 'integration', 'staging', 'production')"
  type        = string
}

variable "region" {
  description = "AWS Region for infrastructure deployment"
  type        = string
}

variable "container_image" {
  description = "Public ECR image URI for platform container (used by bastion and ECS bootstrap)"
  type        = string
}

variable "target_account_id" {
  description = "Target AWS account ID for cross-account deployment. If empty, uses current account."
  type        = string
  default     = ""
}

variable "app_code" {
  description = "Application code for tagging (CMDB Application ID)"
  type        = string
}

variable "service_phase" {
  description = "Service phase for tagging (development, staging, or production)"
  type        = string
}

variable "cost_center" {
  description = "Cost center for tagging (3-digit cost center code)"
  type        = string
}

# =============================================================================
# ArgoCD Bootstrap Configuration Variables
# =============================================================================

variable "repository_url" {
  description = "Git repository URL for cluster configuration"
  type        = string
}

variable "repository_branch" {
  description = "Git branch to use for cluster configuration"
  type        = string
  default     = "main"
}

# =============================================================================
# Bastion Configuration Variables
# =============================================================================

variable "enable_bastion" {
  description = "Enable ECS Fargate bastion for break-glass/development access to the cluster"
  type        = bool
  default     = false
}

# =============================================================================
# Fleet-DB Access Configuration
# =============================================================================

variable "hyperfleet_operator_role_arn" {
  description = "IAM role ARN of the hyperfleet-operator (from regional-cluster). Creates an EKS access entry so the operator can authenticate to fleet-db via IAM."
  type        = string
  default     = ""
}

variable "platform_api_role_arn" {
  description = "IAM role ARN of the platform-api (from regional-cluster). Creates an EKS access entry so the API can authenticate to fleet-db via IAM."
  type        = string
  default     = ""
}
