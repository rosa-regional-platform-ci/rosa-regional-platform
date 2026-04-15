variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string
}

variable "cross_region_backup_vault_arn" {
  description = "ARN of a backup vault in a secondary region for cross-region copies (leave empty to skip)"
  type        = string
  default     = ""
}
