# =============================================================================
# HyperShift OIDC Module - Input Variables
# =============================================================================

variable "cluster_id" {
  description = "Management cluster identifier, used for S3 bucket naming and resource prefixes"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_id))
    error_message = "cluster_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "eks_cluster_name" {
  description = "EKS cluster name for Pod Identity association"
  type        = string
}

variable "openshift_pull_secret_filename" {
  description = "Optional path to OpenShift pull secret JSON file. If not provided, secret is created empty and must be populated manually."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
