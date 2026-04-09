# =============================================================================
# Required Variables
# =============================================================================

variable "cluster_id" {
  description = "Regional cluster identifier for resource naming (e.g., rc01)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the ElastiCache cluster will be deployed"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for the ElastiCache subnet group (multi-AZ requires ≥2)"
  type        = list(string)
}

variable "node_security_group_id" {
  description = "EKS node security group ID — granted ingress on Redis port 6379"
  type        = string
}

# =============================================================================
# Optional Variables
# =============================================================================

variable "node_type" {
  description = "ElastiCache node instance type"
  type        = string
  default     = "cache.r7g.large"
}

variable "engine_version" {
  description = "Redis engine version in <major>.<minor> format (e.g. 7.0, 7.2). Redis 7.x supports TLS without a mandatory auth token."
  type        = string
  default     = "7.0"
}

variable "multi_az" {
  description = "Enable Multi-AZ with automatic failover (adds one replica node, recommended for production)"
  type        = bool
  default     = false
}
