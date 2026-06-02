# =============================================================================
# Regional OIDC Module - Input Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier, used for resource naming"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.regional_id))
    error_message = "regional_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "region_ou_path" {
  description = "AWS Organizations OU path for MC accounts (e.g. o-abc123/r-abc1/ou-abc1-abc12345/). The module appends /* for the IAM trust policy wildcard."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]+/r-[a-z0-9]+/ou-[a-z0-9]+-[a-z0-9]+(/ou-[a-z0-9]+-[a-z0-9]+)*/", var.region_ou_path))
    error_message = "region_ou_path must be a valid AWS Organizations OU path ending with /: o-xxx/r-xxx/ou-xxx-xxx/"
  }
}