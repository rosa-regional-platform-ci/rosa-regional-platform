# =============================================================================
# Required Variables
# =============================================================================

variable "regional_id" {
  description = "Regional cluster identifier for resource naming"
  type        = string
}

variable "vpc_link_id" {
  description = "API Gateway v2 VPC Link ID (shared with platform API gateway)"
  type        = string
}

variable "alb_listener_arn" {
  description = "ALB listener ARN for VPC Link integration target"
  type        = string
}
