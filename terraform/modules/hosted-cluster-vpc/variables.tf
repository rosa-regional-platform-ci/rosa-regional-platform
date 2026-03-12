# =============================================================================
# Hosted Cluster VPC Module - Input Variables
# =============================================================================

variable "cluster_name" {
  description = "Name of the hosted cluster. Used for VPC resource naming."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.cluster_name))
    error_message = "cluster_name must contain only lowercase letters, numbers, and hyphens."
  }
}

# =============================================================================
# VPC and networking configuration
# =============================================================================

variable "vpc_cidr" {
  description = "CIDR block for the VPC. Choose non-overlapping range for your environment."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets used by load balancers"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 1
    error_message = "Must provide at least 1 public subnet for NAT gateway."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets where hosted cluster worker nodes will be deployed"
  type        = list(string)
  default     = ["10.0.0.0/19", "10.0.32.0/19", "10.0.64.0/19"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 1
    error_message = "Must provide at least 1 private subnet for worker nodes."
  }
}

variable "availability_zones" {
  description = "List of availability zones. If empty, will auto-detect AZs in the region."
  type        = list(string)
  default     = []
}

variable "single_nat_gateway" {
  description = "Use a single NAT gateway for all private subnets (cost savings for dev/test). Set to false for per-AZ high availability."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags to apply to all resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# Validation Rules
# =============================================================================

# Ensure private and public subnet counts match
locals {
  subnet_count_validation = length(var.private_subnet_cidrs) == length(var.public_subnet_cidrs) ? true : tobool("Private and public subnet counts must match")
}
