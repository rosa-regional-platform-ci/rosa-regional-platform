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
# Advanced security configuration options
# =============================================================================

variable "enable_pod_security_standards" {
  description = "Enable Kubernetes Pod Security Standards"
  type        = bool
  default     = true
}

variable "enable_karpenter" {
  description = "Install Karpenter and its supporting infrastructure (bootstrap node group, IRSA, SQS interruption queue). Set to true only for management clusters that use RHEL FIPS workload nodes."
  type        = bool
  default     = false
}

variable "ami_kms_key_arn" {
  description = "ARN of the CMK in the AMI build account (791666871613) used to encrypt RHEL FIPS node AMI snapshots. Required for cross-account AMI launch via Karpenter."
  type        = string
  default     = ""
}

