# =============================================================================
# Hosted Cluster IAM Configuration - Variables
# =============================================================================

variable "cluster_name" {
  description = "Name of the hosted cluster (must match the HostedCluster CR name)"
  type        = string
}

variable "oidc_base_url" {
  description = "CloudFront base URL for OIDC (from MC terraform output: oidc_cloudfront_domain, prefixed with https://)"
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
