# =============================================================================
# ROSA Authorization Module - Variables
#
# This module creates AWS resources for ROSA Cedar/AVP-based authorization:
# - DynamoDB tables for accounts, admins, groups, policies, attachments
# - IAM roles for Pod Identity access to DynamoDB and AVP
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name for Pod Identity associations"
  type        = string
}

# =============================================================================
# DynamoDB Configuration
# =============================================================================

variable "billing_mode" {
  description = "DynamoDB billing mode (PAY_PER_REQUEST or PROVISIONED)"
  type        = string
  default     = "PAY_PER_REQUEST"

  validation {
    condition     = contains(["PAY_PER_REQUEST", "PROVISIONED"], var.billing_mode)
    error_message = "billing_mode must be PAY_PER_REQUEST or PROVISIONED"
  }
}

variable "enable_point_in_time_recovery" {
  description = "Enable point-in-time recovery for DynamoDB tables (recommended for production)"
  type        = bool
  default     = false
}

variable "enable_deletion_protection" {
  description = "Enable deletion protection for DynamoDB tables (recommended for production)"
  type        = bool
  default     = false
}

# =============================================================================
# Pod Identity Configuration
# =============================================================================

variable "frontend_api_namespace" {
  description = "Kubernetes namespace where the Frontend API runs"
  type        = string
  default     = "platform-api"
}

variable "frontend_api_service_account" {
  description = "Kubernetes service account name for the Frontend API"
  type        = string
  default     = "platform-api-sa"
}

# =============================================================================
# Bootstrap Configuration
# =============================================================================

variable "bootstrap_accounts" {
  description = "List of AWS account IDs to bootstrap in the accounts table as privileged. Used for initial admin access before platform-api can provision accounts."
  type        = list(string)
  default     = []
}

# =============================================================================
# Tagging
# =============================================================================

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
