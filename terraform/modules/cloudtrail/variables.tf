variable "cluster_id" {
  description = "Unique cluster identifier used as a name prefix for all resources"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_id))
    error_message = "cluster_id must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "force_destroy" {
  description = "Allow the CloudTrail S3 bucket to be destroyed even if it contains objects. Set to true only for ephemeral/CI environments; leave false for production."
  type        = bool
  default     = false
}
