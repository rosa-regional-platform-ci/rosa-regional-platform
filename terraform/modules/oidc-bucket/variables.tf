variable "regional_id" {
  description = "Regional cluster identifier, used for S3 bucket naming and CloudFront comment"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.regional_id))
    error_message = "regional_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "mc_org_paths" {
  description = <<-EOT
    List of AWS Organizations path patterns for the OU containing management clusters.
    Used in the aws:PrincipalOrgPaths bucket policy condition to allow HyperShift operator
    roles in any MC account within the specified OU to write OIDC documents.

    Format: "<org_id>/<root_id>/<ou_id>/*"
    Example: ["o-aa111bb222cc/r-ab12/ou-ab12-cd34ef56/*"]

    Populated automatically by provision-infra-rc.sh by querying the Organizations API
    for the RC account's own OU path (RC and MC accounts share the same OU depth).
    When empty, no cross-account write statement is added to the bucket policy.
  EOT
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}
