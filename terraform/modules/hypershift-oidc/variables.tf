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

variable "openshift_pull_secret_ssm_path" {
  description = "SSM parameter path for OpenShift pull secret. Leave empty to create a placeholder (suitable for CI/ephemeral environments where HyperShift clusters are not deployed)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
