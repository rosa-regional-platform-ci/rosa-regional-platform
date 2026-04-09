variable "regional_id" {
  description = "Regional cluster identifier, used for S3 bucket naming and CloudFront comment"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.regional_id))
    error_message = "regional_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "mc_account_ids" {
  description = "List of AWS account IDs for management clusters that need cross-account write access to the shared OIDC bucket. Update and re-apply RC Terraform when provisioning a new management cluster."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.mc_account_ids : can(regex("^[0-9]{12}$", id))])
    error_message = "All mc_account_ids must be 12-digit AWS account IDs."
  }
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
