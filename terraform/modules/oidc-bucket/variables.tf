variable "management_cluster_id" {
  description = "Management cluster identifier, used for S3 bucket naming and CloudFront comment"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.management_cluster_id))
    error_message = "management_cluster_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "mc_account_id" {
  description = "AWS account ID of the management cluster --- used to grant the HyperShift operator cross-account write access to the OIDC bucket"
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.mc_account_id))
    error_message = "mc_account_id must be a 12-digit AWS account ID."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
