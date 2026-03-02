# =============================================================================
# Required variables
# =============================================================================

variable "cluster_type" {
  description = "Type of cluster: 'regional-cluster' or 'management-cluster'"
  type        = string

  validation {
    condition     = contains(["regional-cluster", "management-cluster"], var.cluster_type)
    error_message = "Cluster type must be either 'regional-cluster' or 'management-cluster'."
  }
}

variable "cluster_id" {
  description = "Unique identifier for the cluster, used as the base name for all resources."
  type        = string
}

# =============================================================================
# Kubernetes configuration
# =============================================================================

variable "cluster_version" {
  description = "EKS cluster version"
  type        = string
  default     = "1.34"

  validation {
    condition     = can(regex("^1\\.(2[89]|3[0-9])$", var.cluster_version))
    error_message = "Cluster version must be more modern."
  }
}

# =============================================================================
# VPC inputs (from vpc module)
# =============================================================================

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be deployed"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block (used for security group rules)"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for EKS worker nodes"
  type        = list(string)
}

variable "cluster_security_group_id" {
  description = "Pre-created security group ID for EKS cluster control plane"
  type        = string
}

variable "vpc_endpoints_security_group_id" {
  description = "Pre-created security group ID for VPC endpoints"
  type        = string
}

# =============================================================================
# EKS node group configuration
# =============================================================================

variable "node_instance_types" {
  description = "List of EC2 instance types for worker nodes"
  type        = list(string)
  default     = ["t3.medium", "t3a.medium"]

  validation {
    condition     = length(var.node_instance_types) > 0
    error_message = "Must specify at least one instance type."
  }
}

variable "node_group_desired_size" {
  description = "Desired number of worker nodes"
  type        = number
  default     = 2

  validation {
    condition     = var.node_group_desired_size >= 1 && var.node_group_desired_size <= 100
    error_message = "Node group desired size must be between 1 and 100."
  }
}

variable "node_group_min_size" {
  description = "Minimum number of worker nodes"
  type        = number
  default     = 1

  validation {
    condition     = var.node_group_min_size >= 1
    error_message = "Node group minimum size must be at least 1."
  }
}

variable "node_group_max_size" {
  description = "Maximum number of worker nodes"
  type        = number
  default     = 4

  validation {
    condition     = var.node_group_max_size >= 1
    error_message = "Node group maximum size must be at least 1."
  }
}

variable "node_disk_size" {
  description = "Disk size in GiB for worker nodes"
  type        = number
  default     = 20

  validation {
    condition     = var.node_disk_size >= 20 && var.node_disk_size <= 1000
    error_message = "Node disk size must be between 20 and 1000 GiB."
  }
}

# =============================================================================
# Advanced security configuration options
# =============================================================================

variable "enable_pod_security_standards" {
  description = "Enable Kubernetes Pod Security Standards"
  type        = bool
  default     = true
}

# =============================================================================
# Validation Rules
# =============================================================================

locals {
  node_size_validation = var.node_group_desired_size >= var.node_group_min_size && var.node_group_desired_size <= var.node_group_max_size ? true : tobool("Node group desired size must be between min_size and max_size")
}
