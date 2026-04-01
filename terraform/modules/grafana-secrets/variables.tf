variable "cluster_id" {
  description = "Regional cluster identifier used for resource naming (e.g., 'rc-us-east-1')"
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_id))
    error_message = "cluster_id must contain only lowercase letters, numbers, and hyphens"
  }
}

variable "eks_cluster_name" {
  description = "Name of the EKS regional cluster (used to authenticate the Kubernetes provider)"
  type        = string
}

variable "grafana_admin_username" {
  description = "Grafana admin username"
  type        = string
  default     = "admin"
}

variable "tags" {
  description = "Additional tags to apply to resources"
  type        = map(string)
  default     = {}
}

