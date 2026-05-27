# =============================================================================
# Grafana CloudWatch Logs Module - Input Variables
# =============================================================================

variable "mode" {
  description = "Module mode: 'primary' creates IAM role + Pod Identity (deployed on RC), 'reader' creates a cross-account reader role (deployed on MC)"
  type        = string

  validation {
    condition     = contains(["primary", "reader"], var.mode)
    error_message = "mode must be either 'primary' or 'reader'"
  }
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "regional_id" {
  description = "Regional or management identifier used in resource naming"
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace where Grafana is deployed (primary mode only)"
  type        = string
  default     = "grafana"
}

variable "service_account" {
  description = "Kubernetes service account name for Grafana (primary mode only)"
  type        = string
  default     = "grafana"
}

variable "grafana_role_account_id" {
  description = "AWS account ID where the primary Grafana role lives (reader mode only — used to build the trust policy)"
  type        = string
  default     = ""

  validation {
    condition     = var.grafana_role_account_id == "" || can(regex("^[0-9]{12}$", var.grafana_role_account_id))
    error_message = "grafana_role_account_id must be empty or a 12-digit AWS account ID"
  }
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}
