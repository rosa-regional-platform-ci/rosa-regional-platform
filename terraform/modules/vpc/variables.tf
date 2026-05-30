# =============================================================================
# VPC Module Variables
# =============================================================================

variable "resource_name_base" {
  description = "Base name for all resources (e.g., regional-cluster-x8k2)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "VPC CIDR must be a valid IPv4 CIDR block."
  }
}

variable "availability_zones" {
  description = "List of availability zones. If empty, will auto-detect first 3 AZs in the region."
  type        = list(string)
  default     = []

  validation {
    condition     = length(var.availability_zones) == 0 || length(var.availability_zones) >= 2
    error_message = "If specified, must provide at least 2 availability zones."
  }
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]

  validation {
    condition     = length(var.private_subnet_cidrs) >= 2
    error_message = "Must provide at least 2 private subnets for high availability."
  }

  validation {
    condition = length(var.availability_zones) > 0 ? (
      length(var.private_subnet_cidrs) <= length(var.availability_zones)
      ) : (
      length(var.private_subnet_cidrs) <= 3
    )
    error_message = "Number of private subnet CIDRs cannot exceed available availability zones."
  }
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets (used only for NAT gateway)"
  type        = list(string)
  default     = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]

  validation {
    condition     = length(var.public_subnet_cidrs) >= 1
    error_message = "Must provide at least 1 public subnet for NAT gateway."
  }

  validation {
    condition = length(var.availability_zones) > 0 ? (
      length(var.public_subnet_cidrs) <= length(var.availability_zones)
      ) : (
      length(var.public_subnet_cidrs) <= 3
    )
    error_message = "Number of public subnet CIDRs cannot exceed available availability zones."
  }
}

# Ensure private and public subnet counts match
locals {
  subnet_count_validation = length(var.private_subnet_cidrs) == length(var.public_subnet_cidrs) ? true : tobool("Private and public subnet counts must match")
}
