# =============================================================================
# Hosted Cluster IAM Module - Input Variables
# =============================================================================

variable "cluster_name" {
  description = "Name of the hosted cluster. Used for IAM resource naming and OIDC subject claim paths."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_name))
    error_message = "cluster_name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "oidc_base_url" {
  description = "CloudFront base URL for the OIDC issuer (e.g., https://d1234abcdef.cloudfront.net). Cluster name is appended automatically."
  type        = string

  validation {
    condition     = can(regex("^https://", var.oidc_base_url))
    error_message = "oidc_base_url must start with https://."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
