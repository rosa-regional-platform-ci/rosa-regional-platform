# =============================================================================
# Required Variables
# =============================================================================

variable "vpc_id" {
  description = "VPC ID where the ALB and VPC Link will be created"
  type        = string
}

variable "private_subnet_ids" {
  description = "List of private subnet IDs for ALB and VPC Link placement"
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "At least 2 private subnets are required for ALB high availability."
  }
}

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "node_security_group_id" {
  description = "EKS node/pod security group ID - ALB needs to send traffic to pods via this SG. For EKS Auto Mode, use the cluster_primary_security_group_id."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name - required for tagging target group with eks:eks-cluster-name tag for Auto Mode IAM permissions"
  type        = string
}

# =============================================================================
# ALB and Target Group Configuration
# =============================================================================

variable "target_port" {
  description = "Port on which the backend service receives traffic"
  type        = number
  default     = 8080

  validation {
    condition     = var.target_port >= 1 && var.target_port <= 65535
    error_message = "Target port must be between 1 and 65535."
  }
}

variable "health_check_path" {
  description = "Path for ALB health checks on the backend service"
  type        = string
  default     = "/v0/live"
}

variable "health_check_interval" {
  description = "Interval in seconds between health checks"
  type        = number
  default     = 30

  validation {
    condition     = var.health_check_interval >= 5 && var.health_check_interval <= 300
    error_message = "Health check interval must be between 5 and 300 seconds."
  }
}

variable "health_check_timeout" {
  description = "Timeout in seconds for health check response"
  type        = number
  default     = 5

  validation {
    condition     = var.health_check_timeout >= 2 && var.health_check_timeout <= 120
    error_message = "Health check timeout must be between 2 and 120 seconds."
  }
}

# =============================================================================
# API Gateway Configuration
# =============================================================================

variable "stage_name" {
  description = "API Gateway stage name"
  type        = string
  default     = "prod"

  validation {
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.stage_name))
    error_message = "Stage name can only contain alphanumeric characters, hyphens, and underscores."
  }
}

variable "thanos_target_port" {
  description = "Thanos Receive remote-write port"
  type        = number
  default     = 19291

  validation {
    condition     = var.thanos_target_port >= 1 && var.thanos_target_port <= 65535
    error_message = "Thanos target port must be between 1 and 65535."
  }
}

variable "api_description" {
  description = "Description for the API Gateway REST API"
  type        = string
  default     = "ROSA Regional Platform API"
}

# =============================================================================
# Custom Domain Configuration (Optional)
# =============================================================================

variable "api_domain_name" {
  description = "Custom domain name for the API Gateway (e.g. api.us-east-1.int0.rosa.devshift.net). When null, no custom domain resources are created."
  type        = string
  default     = null

  validation {
    condition     = var.api_domain_name == null || can(regex("^[a-z0-9][a-z0-9.-]+[a-z0-9]$", var.api_domain_name))
    error_message = "api_domain_name must be a valid domain name."
  }
}

variable "regional_hosted_zone_id" {
  description = "Route53 hosted zone ID for the regional delegation zone (e.g. the zone for us-east-1.int0.rosa.devshift.net) in the RC account. Used for ACM DNS validation and the API alias record. When null, ACM cert is created but DNS records must be managed externally."
  type        = string
  default     = null
}
