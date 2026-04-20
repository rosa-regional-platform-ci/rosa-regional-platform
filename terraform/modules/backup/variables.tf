variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string
}

variable "break_glass_role_arn" {
  description = "ARN of the BreakGlass IAM role that is exempt from the backup vault delete/lifecycle deny policy. This role must exist externally (e.g., created by the central account bootstrap). Example: arn:aws:iam::123456789012:role/BreakGlassRole"
  type        = string

  validation {
    condition     = can(regex("^arn:[a-z0-9-]+:iam::[0-9]{12}:role/.+$", var.break_glass_role_arn))
    error_message = "break_glass_role_arn must be a non-empty IAM role ARN (e.g. arn:aws:iam::123456789012:role/BreakGlassRole)."
  }
}

variable "cross_region_backup_vault_arn" {
  description = "ARN of a backup vault in a secondary region for cross-region copies (leave empty to skip)"
  type        = string
  default     = ""
}
